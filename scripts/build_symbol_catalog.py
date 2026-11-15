"""Build the searchable Universe 2 catalog from fictional companies only."""
from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
FIELDS = (
    "symbol", "name", "english_name", "market", "exchange",
    "exchange_name", "currency", "asset_type",
)


def main() -> None:
    companies = json.loads((DATA / "simulated-stocks.json").read_text(encoding="utf-8"))["markets"]
    manifest = {"generated_at": datetime.now(timezone.utc).isoformat(), "markets": {}, "source": "Universe 2 fictional companies"}
    for market, items in companies.items():
        filename = f"stocks-{market.lower()}-01.tsv"
        with (DATA / filename).open("w", encoding="utf-8", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=FIELDS, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            for item in items:
                writer.writerow({
                    **item,
                    "market": market,
                    "asset_type": "FICTIONAL_COMMON_STOCK",
                })
        manifest["markets"][market] = {"count": len(items), "files": [filename]}
    (DATA / "stocks-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Built fictional stock catalog: {sum(len(items) for items in companies.values())} companies")


if __name__ == "__main__":
    main()
