begin;
create table if not exists public.campus_season (
  id integer primary key check(id=1),
  name text not null,
  ends_at timestamptz not null
);
insert into public.campus_season values(1,'Universe 2 상시 시즌','2100-01-01 00:00:00+09') on conflict do nothing;
alter table public.campus_season enable row level security;
revoke all on public.campus_season from anon,authenticated;

create table if not exists public.campus_loans (
  user_id uuid primary key references public.campus_players(user_id) on delete cascade,
  principal numeric(18,2) not null default 0 check(principal>=0),
  accrued_interest numeric(24,10) not null default 0 check(accrued_interest>=0),
  interest_due numeric(18,2) not null default 0 check(interest_due>=0),
  last_accrued_at timestamptz not null default now(),
  billing_day integer check(billing_day between 1 and 31),
  next_due_at timestamptz,
  checked_at timestamptz not null default now(),
  bankrupt_at timestamptz,
  final_equity numeric(24,6)
);
create index if not exists campus_loans_check_queue on public.campus_loans(checked_at) where bankrupt_at is null;
create table if not exists public.campus_loan_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.campus_players(user_id) on delete cascade,
  kind text not null check(kind in ('borrow','repay','interest_charge','interest_payment','bankruptcy')),
  amount numeric(24,6) not null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists campus_loan_events_user_time on public.campus_loan_events(user_id,id desc);
alter table public.campus_loans enable row level security;
alter table public.campus_loan_events enable row level security;
revoke all on public.campus_loans,public.campus_loan_events from anon,authenticated;

create or replace function public.campus_next_billing_date(p_current timestamptz,p_day integer)
returns timestamptz language sql immutable set search_path=public,pg_temp as $$
  with m as (select date_trunc('month',p_current at time zone 'Asia/Seoul')+interval '1 month' as start)
  select (start + (least(p_day,extract(day from start+interval '1 month - 1 day')::integer)-1)*interval '1 day') at time zone 'Asia/Seoul' from m;
$$;

create or replace function public.campus_loan_interest(p_loan public.campus_loans,p_at timestamptz)
returns numeric language sql immutable set search_path=public,pg_temp as $$
  select coalesce(p_loan.accrued_interest,0)+case when p_loan.bankrupt_at is null then
    coalesce(p_loan.principal,0)*0.08*greatest(extract(epoch from p_at-p_loan.last_accrued_at),0)/31536000 else 0 end;
$$;

-- Used under a wallet lock for actions. Missing/stale prices never increase credit or trigger bankruptcy.
create or replace function public.campus_account_value(p_uid uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  with positions as (
    select symbol,sum(case when side='buy' then quantity else -quantity end) as quantity
    from public.campus_trades where user_id=p_uid group by symbol
    having sum(case when side='buy' then quantity else -quantity end)>0
  ), fx as (select * from public.market_quotes where symbol='USD/KRW'),
  holdings as (
    select coalesce(sum(p.quantity*q.price*case when q.currency='USD' then coalesce((select price from fx),1380) else 1 end),0) as value,
      coalesce(bool_and(q.symbol is not null and q.price>0 and q.freshness<>'demo' and q.as_of<=now()+interval '1 minute'
        and q.as_of>=now()-case when q.freshness='end_of_day' then interval '7 days' else interval '2 minutes' end),true) as reliable,
      coalesce(bool_or(q.currency='USD'),false) as usd
    from positions p left join public.market_quotes q using(symbol)
  )
  select jsonb_build_object('gross',w.cash_krw+w.cash_usd*coalesce((select price from fx),1380)+h.value,
    'reliable',h.reliable and (not(h.usd or w.cash_usd>0) or coalesce((select price>0 and freshness<>'demo' and as_of<=now()+interval '1 minute'
      and as_of>=now()-case when freshness='end_of_day' then interval '7 days' else interval '2 minutes' end from fx),false)))
  from public.campus_wallets w cross join holdings h where w.user_id=p_uid;
$$;

create or replace function public.settle_campus_loan(p_uid uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare l public.campus_loans%rowtype; w public.campus_wallets%rowtype;
  t timestamptz:=least(now(),(select ends_at from public.campus_season where id=1));
  charge numeric; paid numeric; value jsonb; equity numeric;
begin
  select * into w from public.campus_wallets where user_id=p_uid for update;
  if not found then return; end if;
  select * into l from public.campus_loans where user_id=p_uid for update;
  if not found or l.bankrupt_at is not null or l.final_equity is not null then return; end if;
  while l.next_due_at is not null and l.next_due_at<=t loop
    l.accrued_interest:=public.campus_loan_interest(l,l.next_due_at);
    l.last_accrued_at:=l.next_due_at;
    charge:=trunc(l.accrued_interest,2);
    l.accrued_interest:=l.accrued_interest-charge;
    l.interest_due:=l.interest_due+charge;
    if charge>0 then insert into public.campus_loan_events(user_id,kind,amount,occurred_at) values(p_uid,'interest_charge',charge,l.next_due_at); end if;
    l.next_due_at:=public.campus_next_billing_date(l.next_due_at,l.billing_day);
  end loop;
  l.accrued_interest:=public.campus_loan_interest(l,t);
  l.last_accrued_at:=greatest(l.last_accrued_at,t);
  if now()>=(select ends_at from public.campus_season where id=1) then
    charge:=trunc(l.accrued_interest,2); l.interest_due:=l.interest_due+charge; l.accrued_interest:=l.accrued_interest-charge;
    if charge>0 then insert into public.campus_loan_events(user_id,kind,amount,occurred_at) values(p_uid,'interest_charge',charge,t); end if;
  end if;
  paid:=least(w.cash_krw,l.interest_due);
  if paid>0 then
    update public.campus_wallets set cash_krw=cash_krw-paid where user_id=p_uid;
    l.interest_due:=l.interest_due-paid;
    insert into public.campus_loan_events(user_id,kind,amount,occurred_at) values(p_uid,'interest_payment',paid,t);
  end if;
  value:=public.campus_account_value(p_uid);
  equity:=(value->>'gross')::numeric-l.principal-l.interest_due-l.accrued_interest;
  if (value->>'reliable')::boolean and l.principal+l.interest_due+l.accrued_interest>0 and equity<=0 then
    l.bankrupt_at:=t; l.final_equity:=equity;
    insert into public.campus_loan_events(user_id,kind,amount,occurred_at) values(p_uid,'bankruptcy',equity,t);
  end if;
  if now()>=(select ends_at from public.campus_season where id=1) then l.final_equity:=equity; end if;
  update public.campus_loans set accrued_interest=l.accrued_interest,interest_due=l.interest_due,
    last_accrued_at=l.last_accrued_at,next_due_at=l.next_due_at,checked_at=now(),bankrupt_at=l.bankrupt_at,final_equity=l.final_equity
    where user_id=p_uid;
end;
$$;

create or replace function public.get_campus_loan_state(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare l public.campus_loans%rowtype; v jsonb; equity numeric; accrued numeric; ending timestamptz;
begin
  select ends_at into ending from public.campus_season where id=1;
  select * into l from public.campus_loans where user_id=p_uid;
  accrued:=public.campus_loan_interest(l,least(now(),ending));
  v:=public.campus_account_value(p_uid);
  equity:=coalesce(l.final_equity,(v->>'gross')::numeric-coalesce(l.principal,0)-coalesce(l.interest_due,0)-accrued);
  return jsonb_build_object('principal',coalesce(l.principal,0),'accrued_interest',accrued,'interest_due',coalesce(l.interest_due,0),
    'annual_rate',0.08,'monthly_estimate',coalesce(l.principal,0)*0.08/12,'net_equity',equity,
    'credit_limit',greatest(floor(equity),0),'available_credit',greatest(floor(equity)-coalesce(l.principal,0),0),
    'can_borrow',coalesce((v->>'reliable')::boolean,false) and coalesce(l.interest_due,0)=0 and l.bankrupt_at is null and now()<ending,
    'next_due_at',l.next_due_at,'billing_day',l.billing_day,'bankrupt_at',l.bankrupt_at,'final_equity',l.final_equity,
    'as_of',now(),'season_ends_at',ending,'season_closed',now()>=ending,
    'events',coalesce((select jsonb_agg(to_jsonb(e) order by id desc) from (select id,kind,amount,occurred_at from public.campus_loan_events where user_id=p_uid order by id desc limit 20)e),'[]'::jsonb));
end;
$$;

create or replace function public.assert_campus_playable(p_uid uuid,p_spending boolean default false)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if now()>=(select ends_at from public.campus_season where id=1) then raise exception '이번 시즌이 종료됐습니다.'; end if;
  perform public.settle_campus_loan(p_uid);
  if exists(select 1 from public.campus_loans where user_id=p_uid and bankrupt_at is not null) then raise exception '파산으로 이번 시즌 참가가 종료됐습니다.'; end if;
  if p_spending and exists(select 1 from public.campus_loans where user_id=p_uid and interest_due>0) then raise exception '미납 이자를 먼저 납부해주세요. 매도와 원화 환전은 가능합니다.'; end if;
end;
$$;

create or replace function public.execute_campus_loan(p_side text,p_amount numeric)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); l public.campus_loans%rowtype; w public.campus_wallets%rowtype; s jsonb;
  payment numeric; charge numeric; interest_paid numeric; principal_paid numeric;
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  if p_side is null or p_side not in ('borrow','repay','repay_all') or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity')
    or p_amount<>trunc(p_amount) or p_amount<0 or p_amount>999999999999999 or (p_side<>'repay_all' and p_amount<1) then raise exception '금액을 1원 이상 정수로 입력해주세요.'; end if;
  select * into w from public.campus_wallets where user_id=uid for update;
  if not found then raise exception '먼저 리그에 참가해주세요.'; end if;
  perform public.assert_campus_playable(uid,p_side='borrow');
  select * into w from public.campus_wallets where user_id=uid;
  insert into public.campus_loans(user_id) values(uid) on conflict do nothing;
  select * into l from public.campus_loans where user_id=uid for update;
  if p_side='borrow' then
    s:=public.get_campus_loan_state(uid);
    if not (s->>'can_borrow')::boolean then raise exception '시세와 이자 납부 상태를 확인한 뒤 대출할 수 있습니다.'; end if;
    if p_amount>(s->>'available_credit')::numeric then raise exception '대출 잔액은 자기자본을 초과할 수 없습니다.'; end if;
    if l.next_due_at is null then
      l.billing_day:=extract(day from now() at time zone 'Asia/Seoul');
      l.next_due_at:=public.campus_next_billing_date(now(),l.billing_day);
      l.last_accrued_at:=now();
    end if;
    l.principal:=l.principal+p_amount;
    update public.campus_wallets set cash_krw=cash_krw+p_amount where user_id=uid;
    insert into public.campus_loan_events(user_id,kind,amount) values(uid,'borrow',p_amount);
  else
    if l.principal+l.interest_due+l.accrued_interest<=0 then raise exception '상환할 대출이 없습니다.'; end if;
    -- Early repayments settle elapsed interest first. Sub-cent interest is carried until full payoff.
    charge:=case when p_side='repay_all' then round(l.accrued_interest,2) else trunc(l.accrued_interest,2) end;
    l.interest_due:=l.interest_due+charge;
    l.accrued_interest:=case when p_side='repay_all' then 0 else l.accrued_interest-charge end;
    if charge>0 then insert into public.campus_loan_events(user_id,kind,amount) values(uid,'interest_charge',charge); end if;
    payment:=case when p_side='repay_all' then l.principal+l.interest_due else p_amount end;
    if payment>w.cash_krw then raise exception '상환할 원화 잔액이 부족합니다.'; end if;
    if payment>l.principal+l.interest_due then raise exception '상환 잔액보다 많습니다. 전액 상환을 이용해주세요.'; end if;
    interest_paid:=least(payment,l.interest_due);
    principal_paid:=payment-interest_paid;
    l.interest_due:=l.interest_due-interest_paid; l.principal:=l.principal-principal_paid;
    update public.campus_wallets set cash_krw=cash_krw-payment where user_id=uid;
    if interest_paid>0 then insert into public.campus_loan_events(user_id,kind,amount) values(uid,'interest_payment',interest_paid); end if;
    if principal_paid>0 then insert into public.campus_loan_events(user_id,kind,amount) values(uid,'repay',principal_paid); end if;
    if l.principal+l.interest_due+l.accrued_interest=0 then l.next_due_at:=null; l.billing_day:=null; end if;
  end if;
  update public.campus_loans set principal=l.principal,accrued_interest=l.accrued_interest,interest_due=l.interest_due,
    next_due_at=l.next_due_at,billing_day=l.billing_day,last_accrued_at=l.last_accrued_at,checked_at=now() where user_id=uid;
  return jsonb_build_object('ok',true,'side',p_side,'loan',public.get_campus_loan_state(uid));
end;
$$;

create or replace function public.settle_campus_loans_batch(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; n integer:=0;
begin
  for r in select w.user_id from public.campus_wallets w join public.campus_loans l using(user_id)
    where l.bankrupt_at is null and l.final_equity is null and l.principal+l.interest_due+l.accrued_interest>0 and l.checked_at<now()-interval '55 seconds'
    order by l.checked_at,w.user_id limit greatest(1,least(coalesce(p_limit,100),200)) for update of w skip locked
  loop perform public.settle_campus_loan(r.user_id); n:=n+1; end loop;
  return jsonb_build_object('processed',n,'at',now());
end;
$$;

alter table public.campus_fx_conversions add column if not exists direction text not null default 'KRW_USD' check(direction in ('KRW_USD','USD_KRW'));
create or replace function public.convert_campus_usd_to_krw(p_usd_amount numeric)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); q public.market_quotes%rowtype; w public.campus_wallets%rowtype; amount numeric;
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  if p_usd_amount is null or p_usd_amount::text in ('NaN','Infinity','-Infinity') or p_usd_amount<0.01 or p_usd_amount<>round(p_usd_amount,4) then raise exception '달러 금액을 확인해주세요.'; end if;
  perform public.assert_campus_playable(uid,false);
  select * into q from public.market_quotes where symbol='USD/KRW';
  if not found or q.price<=0 or q.freshness='demo' or q.as_of>now()+interval '1 minute' or
    q.as_of<now()-(case when q.freshness='end_of_day' then interval '7 days' else interval '2 minutes' end) then raise exception '환율이 갱신된 뒤 다시 환전해주세요.'; end if;
  select * into w from public.campus_wallets where user_id=uid for update;
  if not found or w.cash_usd<p_usd_amount then raise exception '달러 잔액이 부족합니다.'; end if;
  amount:=round(p_usd_amount*q.price,2);
  update public.campus_wallets set cash_usd=cash_usd-p_usd_amount,cash_krw=cash_krw+amount where user_id=uid;
  insert into public.campus_fx_conversions(user_id,krw_amount,usd_amount,fx_krw,direction) values(uid,amount,p_usd_amount,q.price,'USD_KRW');
  perform public.settle_campus_loan(uid);
  return jsonb_build_object('ok',true,'krw_amount',amount,'usd_amount',p_usd_amount,'direction','USD_KRW');
end;
$$;

-- Internal functions never accept arbitrary user IDs from browser callers.
revoke all on function public.campus_next_billing_date(timestamptz,integer),public.campus_loan_interest(public.campus_loans,timestamptz),
  public.campus_account_value(uuid),public.settle_campus_loan(uuid),public.get_campus_loan_state(uuid),
  public.assert_campus_playable(uuid,boolean),public.execute_campus_loan(text,numeric),public.convert_campus_usd_to_krw(numeric),
  public.settle_campus_loans_batch(integer) from public,anon,authenticated;
grant execute on function public.settle_campus_loans_batch(integer) to service_role;

create or replace function public.join_campus_league(p_nickname text, p_school_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_school_id bigint;
  v_nickname text := trim(coalesce(p_nickname,''));
  v_school_name text := trim(coalesce(p_school_name,''));
begin
  if v_uid is null then raise exception '로그인이 필요합니다.'; end if;
  if not (
    coalesce(auth.jwt() -> 'app_metadata' -> 'providers', '[]'::jsonb) ? 'kakao'
    or auth.jwt() -> 'app_metadata' ->> 'provider' = 'kakao'
  ) then
    raise exception '카카오 로그인 후 이용해주세요.';
  end if;
  perform public.assert_campus_playable(v_uid,false);
  if char_length(v_nickname) not between 1 and 20 then raise exception '별명은 1~20자로 입력해주세요.'; end if;
  if char_length(v_school_name) not between 2 and 80 then raise exception '대학교 이름을 2~80자로 입력해주세요.'; end if;

  -- Serialize claims for the same normalized nickname so simultaneous joins cannot claim it twice.
  perform pg_advisory_xact_lock(hashtextextended(lower(v_nickname), 0));
  if exists (
    select 1 from public.campus_players
    where lower(btrim(nickname)) = lower(v_nickname)
      and user_id <> v_uid
  ) then
    raise exception '이미 사용 중인 별명입니다. 다른 별명을 입력해주세요.' using errcode = '23505';
  end if;

  select id into v_school_id from public.campus_schools where lower(name)=lower(v_school_name) limit 1;
  if v_school_id is null then
    insert into public.campus_schools(name) values (v_school_name)
      on conflict do nothing returning id into v_school_id;
    if v_school_id is null then
      select id into v_school_id from public.campus_schools where lower(name)=lower(v_school_name) limit 1;
    end if;
  end if;

  insert into public.campus_players(user_id,nickname,school_id)
    values (v_uid,v_nickname,v_school_id)
    on conflict (user_id) do update set nickname=excluded.nickname;
  insert into public.campus_wallets(user_id) values (v_uid) on conflict (user_id) do nothing;
  return jsonb_build_object('ok',true,'starting_capital_krw',10000000);
end;
$$;

create or replace function public.execute_campus_order(p_symbol text, p_side text, p_quantity integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_quote public.market_quotes%rowtype;
  v_wallet public.campus_wallets%rowtype;
  v_fx numeric(20,6);
  v_fx_as_of timestamptz;
  v_fx_freshness text;
  v_native_total numeric(24,6);
  v_owned bigint;
begin
  if v_uid is null then raise exception '로그인이 필요합니다.'; end if;
  if not (
    coalesce(auth.jwt() -> 'app_metadata' -> 'providers', '[]'::jsonb) ? 'kakao'
    or auth.jwt() -> 'app_metadata' ->> 'provider' = 'kakao'
  ) then
    raise exception '카카오 로그인 후 이용해주세요.';
  end if;
  perform public.assert_campus_playable(v_uid,p_side='buy');
  if p_side is null or p_side not in ('buy','sell') then raise exception '매수 또는 매도를 선택해주세요.'; end if;
  if p_quantity is null or p_quantity not between 1 and 100000 then raise exception '주문 수량을 확인해주세요.'; end if;
  select * into v_quote from public.market_quotes where symbol=p_symbol and market in ('KR','US');
  if not found or not v_quote.is_tradable or v_quote.freshness='demo' then
    raise exception '실제 시세가 연결되기 전에는 주문할 수 없습니다.';
  end if;
  if v_quote.freshness in ('real_time','delayed') and v_quote.as_of < now() - interval '2 minutes' then raise exception '실시간 시세가 오래되어 주문할 수 없습니다.'; end if;
  if v_quote.as_of < now() - interval '7 days' then raise exception '시세가 오래되어 주문할 수 없습니다.'; end if;
  select price,as_of,freshness into v_fx,v_fx_as_of,v_fx_freshness
    from public.market_quotes where symbol='USD/KRW' and market='FX' and is_tradable;
  if v_quote.currency='USD' and (v_fx is null or v_fx_freshness='demo') then raise exception 'USD/KRW 환율 시세가 연결되지 않았습니다.'; end if;
  if v_quote.currency='USD' and v_fx_freshness in ('real_time','delayed') and v_fx_as_of < now() - interval '2 minutes' then raise exception 'USD/KRW 실시간 환율이 오래되어 주문할 수 없습니다.'; end if;
  if v_quote.currency='USD' and v_fx_as_of < now() - interval '7 days' then raise exception 'USD/KRW 환율 시세가 오래되어 주문할 수 없습니다.'; end if;
  v_fx := coalesce(v_fx,1380);

  select * into v_wallet from public.campus_wallets where user_id=v_uid for update;
  if not found then raise exception '먼저 리그에 참가해주세요.'; end if;

  if exists (select 1 from public.market_quotes q where q.symbol = p_symbol and
    (q.freshness in ('demo','end_of_day') or not q.is_tradable or q.as_of < clock_timestamp() - interval '2 minutes' or q.as_of > clock_timestamp() + interval '1 minute'))
  then raise exception '시세가 갱신된 뒤 다시 주문해주세요.'; end if;
  v_native_total := v_quote.price * p_quantity;
  if p_side='sell' then
    select coalesce(sum(case when side='buy' then quantity else -quantity end),0)
      into v_owned from public.campus_trades where user_id=v_uid and symbol=p_symbol;
    if v_owned < p_quantity then raise exception '보유 수량이 부족합니다.'; end if;
    if v_quote.currency='USD' then
      update public.campus_wallets set cash_usd=cash_usd+v_native_total where user_id=v_uid;
    else
      update public.campus_wallets set cash_krw=cash_krw+v_native_total where user_id=v_uid;
    end if;
  else
    if v_quote.currency='USD' and v_wallet.cash_usd < v_native_total then raise exception '달러 잔액이 부족합니다. 먼저 원화를 환전해주세요.'; end if;
    if v_quote.currency='KRW' and v_wallet.cash_krw < v_native_total then raise exception '원화 잔액이 부족합니다.'; end if;
    if v_quote.currency='USD' then
      update public.campus_wallets set cash_usd=cash_usd-v_native_total where user_id=v_uid;
    else
      update public.campus_wallets set cash_krw=cash_krw-v_native_total where user_id=v_uid;
    end if;
  end if;
  insert into public.campus_trades(user_id,symbol,side,quantity,price,currency,fx_krw)
    values (v_uid,p_symbol,p_side,p_quantity,v_quote.price,v_quote.currency,v_fx);
  perform public.settle_campus_loan(v_uid);
  return jsonb_build_object('ok',true,'symbol',p_symbol,'side',p_side,'quantity',p_quantity,'price',v_quote.price,'currency',v_quote.currency,'fx_krw',v_fx);
end;
$$;

create or replace function public.convert_campus_krw_to_usd(p_krw_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_fx numeric(20,6);
  v_fx_as_of timestamptz;
  v_fx_freshness text;
  v_wallet public.campus_wallets%rowtype;
  v_usd numeric(18,4);
begin
  if v_uid is null then raise exception '로그인이 필요합니다.'; end if;
  if not (
    coalesce(auth.jwt() -> 'app_metadata' -> 'providers', '[]'::jsonb) ? 'kakao'
    or auth.jwt() -> 'app_metadata' ->> 'provider' = 'kakao'
  ) then
    raise exception '카카오 로그인 후 이용해주세요.';
  end if;
  perform public.assert_campus_playable(v_uid,true);
  if p_krw_amount is null or p_krw_amount::text in ('NaN','Infinity','-Infinity') or p_krw_amount <> trunc(p_krw_amount) or p_krw_amount < 1000 then raise exception '최소 환전 금액은 1,000원입니다.'; end if;
  select price,as_of,freshness into v_fx,v_fx_as_of,v_fx_freshness
    from public.market_quotes where symbol='USD/KRW' and market='FX' and is_tradable;
  if v_fx is null or v_fx_freshness='demo' then raise exception '환율 시세가 아직 연결되지 않았습니다.'; end if;
  if v_fx_freshness in ('real_time','delayed') and v_fx_as_of < now() - interval '2 minutes' then raise exception '환율 시세가 오래되어 환전할 수 없습니다.'; end if;
  if v_fx_as_of < now() - interval '7 days' then raise exception '환율 시세가 오래되어 환전할 수 없습니다.'; end if;
  select * into v_wallet from public.campus_wallets where user_id=v_uid for update;
  if not found then raise exception '먼저 리그에 참가해주세요.'; end if;
  if v_wallet.cash_krw < p_krw_amount then raise exception '원화 잔액이 부족합니다.'; end if;
  v_usd := round(p_krw_amount / v_fx, 4);
  update public.campus_wallets set cash_krw=cash_krw-p_krw_amount, cash_usd=cash_usd+v_usd where user_id=v_uid;
  insert into public.campus_fx_conversions(user_id,krw_amount,usd_amount,fx_krw) values (v_uid,p_krw_amount,v_usd,v_fx);
  return jsonb_build_object('ok',true,'krw_amount',p_krw_amount,'usd_amount',v_usd,'fx_krw',v_fx);
end;
$$;

create or replace function public.get_my_campus_portfolio()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then raise exception '로그인이 필요합니다.'; end if;
  perform public.settle_campus_loan(v_uid);
  with fx as (
    select coalesce((select price from public.market_quotes where symbol='USD/KRW'),1380) as rate
  ), player as (
    select p.user_id,p.nickname,s.name as school_name,w.cash_krw,w.cash_usd
    from public.campus_players p
    join public.campus_schools s on s.id=p.school_id
    join public.campus_wallets w on w.user_id=p.user_id
    where p.user_id=v_uid
  ), holdings as (
    select t.symbol, max(q.name) as name, max(q.currency) as currency,
      sum(case when t.side='buy' then t.quantity else -t.quantity end)::bigint as quantity,
      max(q.price) as price
    from public.campus_trades t join public.market_quotes q on q.symbol=t.symbol
    where t.user_id=v_uid group by t.symbol
  )
  select jsonb_build_object(
    'profile',(select jsonb_build_object('nickname',p.nickname,'school',s.name,'joined_at',p.joined_at) from public.campus_players p join public.campus_schools s on s.id=p.school_id where p.user_id=v_uid),
    'wallet',(select jsonb_build_object('cash_krw',cash_krw,'cash_usd',cash_usd) from player),
    'fx_krw',(select rate from fx),
    'loan',public.get_campus_loan_state(v_uid),
    'holdings',coalesce((select jsonb_agg(jsonb_build_object('symbol',symbol,'name',name,'currency',currency,'quantity',quantity,'price',price)) from holdings where quantity>0),'[]'::jsonb),
    'trades',coalesce((select jsonb_agg(to_jsonb(t) order by created_at desc) from (select symbol,side,quantity,price,currency,fx_krw,created_at from public.campus_trades where user_id=v_uid order by created_at desc limit 30) t),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

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
      coalesce(l.final_equity,(w.cash_krw + w.cash_usd * fx.rate +
        coalesce(sum(greatest(h.quantity,0) * q.price * case when q.currency='USD' then fx.rate else 1 end),0)
      -coalesce(l.principal,0)-coalesce(l.interest_due,0)-public.campus_loan_interest(l,least(now(),(select ends_at from public.campus_season where id=1))))) as total_krw
    from public.campus_players p
    join public.campus_schools s on s.id=p.school_id
    join public.campus_wallets w on w.user_id=p.user_id
    left join public.campus_loans l on l.user_id=p.user_id
    cross join fx
    left join holdings h on h.user_id=p.user_id
    left join public.market_quotes q on q.symbol=h.symbol
    group by p.user_id,p.nickname,s.name,w.cash_krw,w.cash_usd,fx.rate,l.user_id
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
    'popular_stocks',public.get_campus_popular_stocks(),
    'season',(select jsonb_build_object('name',name,'ends_at',ends_at,'closed',now()>=ends_at) from public.campus_season where id=1)
  );
$$;
alter table public.campus_action_receipts drop constraint if exists campus_action_receipts_kind_check;
alter table public.campus_action_receipts add constraint campus_action_receipts_kind_check check(kind in ('order','exchange','loan'));
create or replace function public.submit_campus_action(p_request_id uuid, p_kind text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_receipt public.campus_action_receipts%rowtype;
  v_result jsonb;
begin
  if v_uid is null then raise exception '로그인이 필요합니다.'; end if;
  if not (coalesce(auth.jwt()->'app_metadata'->'providers','[]'::jsonb) ? 'kakao'
    or coalesce(auth.jwt()->'app_metadata'->>'provider','')='kakao') then raise exception '카카오 로그인 후 이용해주세요.'; end if;
  if p_request_id is null or p_kind is null or p_kind not in ('order','exchange','loan') or p_payload is null or jsonb_typeof(p_payload)<>'object'
    then raise exception '요청 정보를 확인해주세요.'; end if;
  if not exists(select 1 from public.campus_players where user_id=v_uid) then raise exception '먼저 리그에 참가해주세요.'; end if;
  insert into public.campus_action_receipts(user_id,request_id,kind,payload)
    values(v_uid,p_request_id,p_kind,p_payload) on conflict do nothing;
  select * into v_receipt from public.campus_action_receipts where user_id=v_uid and request_id=p_request_id for update;
  if v_receipt.kind<>p_kind or v_receipt.payload<>p_payload then raise exception '이전 요청과 내용이 다릅니다.'; end if;
  if v_receipt.result is not null then return v_receipt.result; end if;
  perform public.settle_campus_loan(v_uid);
  if exists(select 1 from public.campus_loans where user_id=v_uid and bankrupt_at is not null)
    or now()>=(select ends_at from public.campus_season where id=1) then
    v_result:=jsonb_build_object('ok',false,'message','이번 시즌 참가가 종료됐습니다. 내 투자에서 상태를 확인해주세요.');
    update public.campus_action_receipts set result=v_result where user_id=v_uid and request_id=p_request_id;
    return v_result;
  end if;
  if p_kind='order' then
    if jsonb_typeof(p_payload->'quantity') is distinct from 'number'
      or (p_payload->>'quantity')::numeric <> trunc((p_payload->>'quantity')::numeric)
      then raise exception '주문 수량은 정수로 입력해주세요.'; end if;
    v_result := public.execute_campus_order(p_payload->>'symbol',p_payload->>'side',(p_payload->>'quantity')::integer);
  elsif p_kind='exchange' then
    if jsonb_typeof(p_payload->'amount') is distinct from 'number' then raise exception '환전 금액을 확인해주세요.'; end if;
    if coalesce(p_payload->>'direction','KRW_USD')='KRW_USD' then
      v_result := public.convert_campus_krw_to_usd((p_payload->>'amount')::numeric);
    elsif p_payload->>'direction'='USD_KRW' then
      v_result := public.convert_campus_usd_to_krw((p_payload->>'amount')::numeric);
    else raise exception '환전 방향을 확인해주세요.'; end if;
  else
    if jsonb_typeof(p_payload->'amount') is distinct from 'number' then raise exception '대출·상환 금액을 확인해주세요.'; end if;
    v_result:=public.execute_campus_loan(p_payload->>'side',(p_payload->>'amount')::numeric);
  end if;
  update public.campus_action_receipts set result=v_result where user_id=v_uid and request_id=p_request_id;
  return v_result;
end;
$$;
revoke all on function public.execute_campus_order(text,text,integer),public.convert_campus_krw_to_usd(numeric) from public,anon,authenticated;
notify pgrst, 'reload schema';
commit;
