# Reserve-offer keeper

Off-chain server keeper that posts and rebalances `VAULT_SPREAD`
reserve offers on `LiquidityVaultV2`. See
[`docs/HOOK-RISK-RUNBOOK.md`](../../docs/HOOK-RISK-RUNBOOK.md) §3.4 for
the policy.

## Requirements

- Node.js 20+
- The keeper key must be the vault `owner()` —
  `offerReserveToHookWithMode` and `rebalanceOfferWithMode` are both
  `onlyOwner`.

## Install

```bash
cd scripts/keeper
npm install
```

## Configure

```bash
export ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc
export KEEPER_PRIVATE_KEY=0x...        # vault owner key
# Production (Arbitrum One, V2.1, Apr 2026):
export VAULT=0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0       # LiquidityVaultV2
export VAULT_LENS=0x12e86890b75fdee22a35be66550373936d883551  # VaultLens (vaultStatus reads)
export HOOK=0x486579DE6391053Df88a073CeBd673dd545200cC        # DynamicFeeHookV2

# Tunables (defaults shown)
export SPREAD_BPS=25
export REBALANCE_DRIFT_BPS=50
export MAX_OFFER_BPS_OF_IDLE=500       # 5% of idle asset per offer
export OFFER_TTL_SECONDS=900           # 15 min
export MIN_SELL_AMOUNT=1000000         # 1 USDC at 6 decimals
export INTERVAL_MS=60000               # base sleep between ticks
export JITTER_MS=15000                 # random extra sleep, [0, JITTER_MS]
export GAS_SAFETY_MULTIPLIER=3         # require expectedSpread >= 3 * gasCost
export ASSET_PER_NATIVE_E18=0          # asset units per 1e18 wei native;
                                       # 0 disables the profitability guard

# Optional telemetry / alerting
export METRICS_HOST=127.0.0.1          # Prometheus scrape bind address
export METRICS_PORT=0                  # 0 disables; use 9464 for /metrics
export ALERT_WEBHOOK_URL=              # Slack/Discord-compatible webhook
export ALERT_COOLDOWN_SECONDS=600
```

## Run

```bash
# Dry run (simulates only)
npm run keeper:dry

# Single tick (broadcasts)
npm run keeper:once

# Loop (broadcasts every INTERVAL_MS, default 1 min)
npm run keeper:loop

# Loop with local Prometheus metrics enabled
METRICS_PORT=9464 npm run keeper:loop
curl http://127.0.0.1:9464/metrics
```

## Prometheus telemetry (no Docker)

The keeper exposes Prometheus text-format metrics directly from Node's
built-in HTTP server when `METRICS_PORT` is non-zero. No exporter,
container, or `prom-client` dependency is required. Keep the default
`METRICS_HOST=127.0.0.1` when Prometheus runs on the same VM; if you
scrape from another host, bind only to a private interface or VPN address
and firewall the port.

Example keeper env for a local Prometheus scrape:

```env
METRICS_HOST=127.0.0.1
METRICS_PORT=9464
```

The repo includes a minimal standalone Prometheus config at
[`prometheus.yml`](./prometheus.yml):

```bash
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo cp prometheus.yml /etc/prometheus/prometheus.yml
```

Install Prometheus from the upstream Linux tarball rather than Docker:

```bash
curl -LO https://github.com/prometheus/prometheus/releases/download/v<VERSION>/prometheus-<VERSION>.linux-amd64.tar.gz
tar xzf prometheus-<VERSION>.linux-amd64.tar.gz
sudo install -m 0755 prometheus-<VERSION>.linux-amd64/prometheus /usr/local/bin/prometheus
sudo install -m 0755 prometheus-<VERSION>.linux-amd64/promtool /usr/local/bin/promtool
sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
promtool check config /etc/prometheus/prometheus.yml
```

Optional systemd unit for Prometheus at
`/etc/systemd/system/prometheus.service`:

```ini
[Unit]
Description=Prometheus monitoring
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
   --config.file=/etc/prometheus/prometheus.yml \
   --storage.tsdb.path=/var/lib/prometheus \
   --web.listen-address=127.0.0.1:9090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable it with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
curl http://127.0.0.1:9090/api/v1/targets
```

## What it does each tick

1. Verifies the keeper key is the vault `owner()`.
2. Reads `vaultStatus()`. Skips on `PAUSED` / `UNCONFIGURED`.
3. Reads `getOfferHealth(poolKey, vault)` from the hook.
4. Reads `failedDistribution[asset]` from the hook and warns if > 0.
5. Computes `sellAmount = idleAsset * MAX_OFFER_BPS_OF_IDLE / 10_000`,
   skips if below `MIN_SELL_AMOUNT`.
6. Computes `vaultSqrtPriceX96` from current pool sqrtP and
   `SPREAD_BPS` (direction depends on which side of the pool `asset`
   sits — currency0 vs currency1).
7. If no active offer → `offerReserveToHookWithMode(..., VAULT_SPREAD)`.
   If active and `|driftBps| >= REBALANCE_DRIFT_BPS` →
   `rebalanceOfferWithMode(..., VAULT_SPREAD)`. Otherwise no-op.

## Production deployment (Contabo / systemd)

Drop a `systemd` unit at `/etc/systemd/system/the-pool-keeper.service`:

```ini
[Unit]
Description=The Pool reserve keeper
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/the-pool/scripts/keeper
EnvironmentFile=/etc/the-pool/keeper.env
ExecStart=/usr/bin/npm run keeper:loop
Restart=always
RestartSec=10
User=keeper

[Install]
WantedBy=multi-user.target
```

`/etc/the-pool/keeper.env` should contain the env vars from
**Configure** above and be `chmod 600 root:keeper`. To enable local
Prometheus scraping on the same host, add:

```env
METRICS_HOST=127.0.0.1
METRICS_PORT=9464
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now the-pool-keeper
sudo journalctl -u the-pool-keeper -f
```
