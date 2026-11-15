
create or replace function public.get_campus_quote_targets(p_after text default '')
returns jsonb language sql security definer set search_path=public,pg_temp as $$
  select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) from (
    select symbol,market,name,currency,source from public.market_quotes q
    where market in ('KR','US') and symbol>p_after and updated_at<now()-interval '45 seconds'
      and exists(select 1 from public.campus_trades t where t.symbol=q.symbol
        group by t.user_id having sum(case when side='buy' then quantity else -quantity end)>0)
    order by symbol limit 20
  ) q;
$$;
revoke all on function public.get_campus_quote_targets(text) from public,anon,authenticated;
grant execute on function public.get_campus_quote_targets(text) to service_role;
notify pgrst, 'reload schema';
