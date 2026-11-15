begin;
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
  return jsonb_build_object('ok',true,'symbol',p_symbol,'side',p_side,'quantity',p_quantity,'price',v_quote.price,'currency',v_quote.currency,'fx_krw',v_fx);
end;
$$;


-- One receipt per logical action. Wallet change, trade and receipt commit together.
create table if not exists public.campus_action_receipts (
  user_id uuid not null references public.campus_players(user_id) on delete cascade,
  request_id uuid not null,
  kind text not null check (kind in ('order','exchange')),
  payload jsonb not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);
alter table public.campus_action_receipts enable row level security;
revoke all on public.campus_action_receipts from anon, authenticated;
create index if not exists campus_trades_player_symbol on public.campus_trades(user_id,symbol);

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
    or auth.jwt()->'app_metadata'->>'provider'='kakao') then raise exception '카카오 로그인 후 이용해주세요.'; end if;
  if p_request_id is null or p_kind is null or p_kind not in ('order','exchange') or p_payload is null or jsonb_typeof(p_payload)<>'object'
    then raise exception '요청 정보를 확인해주세요.'; end if;
  if not exists(select 1 from public.campus_players where user_id=v_uid) then raise exception '먼저 리그에 참가해주세요.'; end if;
  insert into public.campus_action_receipts(user_id,request_id,kind,payload)
    values(v_uid,p_request_id,p_kind,p_payload) on conflict do nothing;
  select * into v_receipt from public.campus_action_receipts where user_id=v_uid and request_id=p_request_id for update;
  if v_receipt.kind<>p_kind or v_receipt.payload<>p_payload then raise exception '이전 요청과 내용이 다릅니다.'; end if;
  if v_receipt.result is not null then return v_receipt.result; end if;
  if p_kind='order' then
    if jsonb_typeof(p_payload->'quantity') is distinct from 'number'
      or (p_payload->>'quantity')::numeric <> trunc((p_payload->>'quantity')::numeric)
      then raise exception '주문 수량은 정수로 입력해주세요.'; end if;
    v_result := public.execute_campus_order(p_payload->>'symbol',p_payload->>'side',(p_payload->>'quantity')::integer);
  else
    if jsonb_typeof(p_payload->'amount') is distinct from 'number' then raise exception '환전 금액을 확인해주세요.'; end if;
    v_result := public.convert_campus_krw_to_usd((p_payload->>'amount')::numeric);
  end if;
  update public.campus_action_receipts set result=v_result where user_id=v_uid and request_id=p_request_id;
  return v_result;
end;
$$;
revoke all on function public.submit_campus_action(uuid,text,jsonb) from public;
grant execute on function public.submit_campus_action(uuid,text,jsonb) to authenticated;
grant execute on function public.get_campus_league_overview() to service_role;
notify pgrst, 'reload schema';

commit;
