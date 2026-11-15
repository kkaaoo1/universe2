begin;
-- Search interest stores only the last resolved stock per user, never raw search text.
create table if not exists public.campus_stock_searches (
  user_id uuid not null references auth.users(id) on delete cascade,
  symbol text not null references public.market_quotes(symbol) on delete cascade,
  searched_at timestamptz not null default now(),
  primary key (user_id,symbol)
);
create index if not exists campus_stock_searches_recent on public.campus_stock_searches(searched_at,symbol);
alter table public.campus_stock_searches enable row level security;
revoke all on public.campus_stock_searches from anon,authenticated;

create or replace function public.record_campus_stock_search(p_symbol text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_uid uuid:=auth.uid();
  v_symbol text:=upper(btrim(p_symbol));
  v_last timestamptz;
begin
  if v_uid is null or not (
    coalesce(auth.jwt()->'app_metadata'->'providers','[]'::jsonb) ? 'kakao'
    or coalesce(auth.jwt()->'app_metadata'->>'provider','')='kakao'
  ) then raise exception '카카오 로그인이 필요합니다.'; end if;
  if not exists(select 1 from public.market_quotes where symbol=v_symbol and market in ('KR','US') and freshness<>'demo') then return false; end if;
  perform pg_advisory_xact_lock(hashtextextended('stock-search:'||v_uid::text,0));
  select searched_at into v_last from public.campus_stock_searches where user_id=v_uid and symbol=v_symbol;
  if v_last>now()-interval '1 hour' then return true; end if;
  if (v_last is null or v_last<now()-interval '24 hours') and
     (select count(*) from public.campus_stock_searches where user_id=v_uid and searched_at>=now()-interval '24 hours')>=60 then return false; end if;
  insert into public.campus_stock_searches(user_id,symbol) values(v_uid,v_symbol)
  on conflict(user_id,symbol) do update set searched_at=now();
  return true;
end;
$$;
revoke all on function public.record_campus_stock_search(text) from public,anon;
grant execute on function public.record_campus_stock_search(text) to authenticated;

create or replace function public.get_campus_popular_stocks()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  with positions as (
    select user_id,symbol from public.campus_trades
    group by user_id,symbol having sum(case when side='buy' then quantity else -quantity end)>0
  ), holders as (
    select symbol,count(*) as holder_count from positions group by symbol
  ), searches as (
    select symbol,count(*) as search_count from public.campus_stock_searches
    where searched_at>=now()-interval '7 days' group by symbol
  ), counts as (
    select q.symbol,q.market,q.name,coalesce(h.holder_count,0) as holder_count,coalesce(s.search_count,0) as search_count
    from public.market_quotes q left join holders h using(symbol) left join searches s using(symbol)
    where q.market in ('KR','US') and (coalesce(h.holder_count,0)>0 or coalesce(s.search_count,0)>0)
  ), ranked as (
    select *,row_number() over(partition by market order by holder_count desc,search_count desc,symbol) as held_rank,
      row_number() over(partition by market order by search_count desc,holder_count desc,symbol) as search_rank
    from counts
  )
  select coalesce(jsonb_agg(jsonb_build_object('symbol',symbol,'market',market,'name',name,
    'holder_count',holder_count,'search_count',search_count) order by holder_count desc,search_count desc,symbol),'[]'::jsonb)
  from ranked where (holder_count>0 and held_rank<=20) or (search_count>0 and search_rank<=20);
$$;
revoke all on function public.get_campus_popular_stocks() from public,anon,authenticated;
grant execute on function public.get_campus_popular_stocks() to service_role;

create or replace function public.get_campus_league_overview()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  with fx as (
    select coalesce((select price from public.market_quotes where symbol='USD/KRW'),1380) as rate
  ), holdings as (
    select t.user_id,t.symbol,
      sum(case when t.side='buy' then t.quantity else -t.quantity end)::numeric as quantity
    from public.campus_trades t group by t.user_id,t.symbol
  ), values_by_player as (
    select p.user_id,p.nickname,s.name as school_name,
      (w.cash_krw + w.cash_usd * fx.rate +
        coalesce(sum(greatest(h.quantity,0) * q.price * case when q.currency='USD' then fx.rate else 1 end),0)
      ) as total_krw
    from public.campus_players p
    join public.campus_schools s on s.id=p.school_id
    join public.campus_wallets w on w.user_id=p.user_id
    cross join fx
    left join holdings h on h.user_id=p.user_id
    left join public.market_quotes q on q.symbol=h.symbol
    group by p.user_id,p.nickname,s.name,w.cash_krw,w.cash_usd,fx.rate
  ), scored as (
    select *, total_krw - 10000000 as profit_krw,
      (total_krw - 10000000) / 10000000 * 100 as return_pct
    from values_by_player
  ), schools as (
    select school_name,count(*) as players,
      sum(profit_krw) as profit_krw,avg(return_pct) as avg_return_pct
    from scored group by school_name
  )
  select jsonb_build_object(
    'quotes',coalesce((select jsonb_agg(jsonb_build_object(
      'symbol',symbol,'market',market,'name',name,'price',price,'currency',currency,
      'change_pct',change_pct,'source',source,'freshness',freshness,'is_tradable',is_tradable,'as_of',as_of
    ) order by market,symbol) from public.market_quotes),'[]'::jsonb),
    'schools',coalesce((select jsonb_agg(jsonb_build_object(
      'school',school_name,'players',players,'profit_krw',profit_krw,'avg_return_pct',avg_return_pct
    ) order by avg_return_pct desc) from schools),'[]'::jsonb),
    'best',coalesce((select jsonb_build_object('nickname',nickname,'school',school_name,'profit_krw',profit_krw,'return_pct',return_pct)
      from scored order by return_pct desc, nickname limit 1),'null'::jsonb),
    'worst',coalesce((select jsonb_build_object('nickname',nickname,'school',school_name,'profit_krw',profit_krw,'return_pct',return_pct)
      from scored order by return_pct asc, nickname limit 1),'null'::jsonb),
    'participant_count',(select count(*) from public.campus_players),
    'popular_stocks',public.get_campus_popular_stocks()
  );
$$;

create or replace function public.get_campus_quote_targets(p_after text default '')
returns jsonb language sql security definer set search_path=public,pg_temp as $$
  with popular as materialized (
    select p->>'symbol' as symbol from jsonb_array_elements(public.get_campus_popular_stocks()) p
    where (p->>'search_count')::bigint>0
  )
  select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) from (
    select symbol,market,name,currency,source from public.market_quotes q
    where market in ('KR','US') and symbol>p_after and updated_at<now()-interval '45 seconds'
      and (exists(select 1 from public.campus_trades t where t.symbol=q.symbol
        group by t.user_id having sum(case when side='buy' then quantity else -quantity end)>0)
        or exists(select 1 from popular p where p.symbol=q.symbol))
    order by symbol limit 20
  ) q;
$$;
revoke all on function public.get_campus_quote_targets(text) from public,anon,authenticated;
grant execute on function public.get_campus_quote_targets(text) to service_role;

notify pgrst, 'reload schema';
commit;
