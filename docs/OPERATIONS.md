# Universe 2 운영 방식

## 가상 시장

Cloudflare Worker의 Durable Object가 24개 가상 회사와 USD/KRW 환율을 한 곳에서 보관합니다. Worker Cron Trigger는 매분 시장 가격을 진행하며, 요일이나 공휴일로 멈추지 않습니다. 같은 분 동안 모든 방문자에게 같은 가격을 돌려줍니다. 각 회사는 기준가격에서 20%~400% 범위 안에서 움직이며, 종목별 변동폭은 다릅니다.

Cron Trigger와 가상 가격 게시가 멈추면 2분이 지난 시세는 거래에 쓸 수 없게 서버가 차단합니다. Worker /health에서 configured가 true인지 확인하고, Cloudflare의 Cron Trigger와 실행 로그를 살펴보세요. 가격 생성은 외부 금융 API 호출 없이 동작합니다.

## 계좌와 주문

- Supabase가 참가자, 가상 지갑, 보유 수량, 주문, 대출 및 순위의 기준 데이터입니다.
- 각 주문·환전·대출 요청에는 고유 ID를 기록해 네트워크 응답이 유실돼도 같은 요청이 두 번 처리되지 않게 합니다.
- Supabase Secret Key는 새 Universe 2 Worker에만 등록합니다. 브라우저의 config.js에는 Supabase URL과 publishable key만 둡니다.
- 별도 Supabase 프로젝트를 사용해 기존 universe의 거래와 참가자에 영향을 주지 않습니다.

## 대출과 시즌

대출은 순자산 한도, 연 8% 일할 계산, 매월 원화 이자 납부, 미납 이자 정산 및 파산 잠금을 사용합니다. 매분 Worker가 최대 100명씩 정산하며, 참가자가 포트폴리오를 열거나 거래할 때도 해당 계좌를 정산합니다. Universe 2 시즌 종료일은 2100-01-01 KST입니다.

## 용량

매분 약 25개 시세를 한 번의 upsert 배치로 반영하고, 순위 RPC는 페이지 요청에 따라 계산합니다. 실제 최대 이용자 수는 Cloudflare와 Supabase 플랜 및 동시 조회량에 따라 달라집니다. 대규모 공개 전에는 Cloudflare 사용량, Supabase 데이터베이스 부하 및 Worker 실패율을 확인하세요.
