# deploy-ledger.ps1
# ─────────────────────────────────────────────────────────────────────────────
#  One-shot Ledger deployment for The-Pool on Arbitrum One.
#
#  Prerequisites:
#    1. Ledger plugged in, Ethereum app open, blind signing enabled.
#    2. Copy .env.example → .env  and fill in SENDER and TREASURY.
#       (All Uniswap v4 / token addresses are already pre-filled.)
#    3. Run from the repo root:  .\script\deploy-ledger.ps1
#
#  What it does:
#    - Loads .env
#    - Validates required variables
#    - Runs forge script Deploy.s.sol with --ledger --sender
#    - Verifies all deployed contracts on Arbiscan automatically
#
#  After a successful run, copy the printed contract addresses into:
#    web/.env.local  (NEXT_PUBLIC_VAULT_ARB_ONE, _HOOK_, _DISTRIBUTOR_)
#    Vercel project env vars (Production) for the live site.
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 0. Locate repo root ──────────────────────────────────────────────────────
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# ── 1. Load .env ─────────────────────────────────────────────────────────────
$envFile = Join-Path $repoRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env not found. Run:  cp .env.example .env  then fill in SENDER and TREASURY."
}

Get-Content $envFile |
    Where-Object { $_ -match "^\s*[^#\s]" -and $_ -match "=" } |
    ForEach-Object {
        $parts = $_ -split "=", 2
        $key   = $parts[0].Trim()
        $val   = $parts[1].Split("#")[0].Trim()
        [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
    }

# ── 2. Validate required variables ───────────────────────────────────────────
$required = @("SENDER", "TREASURY", "POOL_MANAGER", "POS_MANAGER",
              "TOKEN0", "TOKEN1", "ASSET_TOKEN", "ARBITRUM_RPC_URL",
              "ETHERSCAN_API_KEY", "ETHERSCAN_VERIFIER_URL")

foreach ($var in $required) {
    $val = [System.Environment]::GetEnvironmentVariable($var, "Process")
    if (-not $val -or $val -match "YOUR_") {
        Write-Error "Missing or placeholder value for $var in .env — please fill it in."
    }
}

$sender   = $env:SENDER
$rpc      = $env:ARBITRUM_RPC_URL
$esKey    = $env:ETHERSCAN_API_KEY
$esUrl    = $env:ETHERSCAN_VERIFIER_URL

Write-Host ""
Write-Host "=== The-Pool — Ledger Deployment to Arbitrum One ===" -ForegroundColor Cyan
Write-Host "Sender (Ledger) : $sender"
Write-Host "Treasury        : $($env:TREASURY)"
Write-Host "PoolManager     : $($env:POOL_MANAGER)"
Write-Host "PositionManager : $($env:POS_MANAGER)"
Write-Host "TOKEN0 (WETH)   : $($env:TOKEN0)"
Write-Host "TOKEN1 (USDC)   : $($env:TOKEN1)"
Write-Host "ASSET_TOKEN     : $($env:ASSET_TOKEN)"
Write-Host ""
Write-Host "Your Ledger will prompt you to sign ~7 transactions." -ForegroundColor Yellow
Write-Host "Press Enter to continue or Ctrl+C to abort."
Read-Host | Out-Null

# ── 3. Run forge script ───────────────────────────────────────────────────────
#    --ledger            : use Ledger hardware wallet (no private key)
#    --sender            : tell forge which address the Ledger holds
#    --broadcast         : submit signed txs to the network
#    --verify            : verify contracts on Arbiscan after deploy
#    --slow              : wait for each tx to confirm before the next
#                          (important for Ledger — avoids nonce collisions)

$forgeArgs = @(
    "script", "script/Deploy.s.sol",
    "--rpc-url", $rpc,
    "--ledger",
    "--sender", $sender,
    "--broadcast",
    "--verify",
    "--etherscan-api-key", $esKey,
    "--verifier-url", $esUrl,
    "--slow"
)

Write-Host ""
Write-Host "Running: forge $($forgeArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

& forge @forgeArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "forge script failed (exit $LASTEXITCODE). Check output above."
}

# ── 4. Print next steps ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Deployment complete! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Copy the FeeDistributor, LiquidityVault, DynamicFeeHook addresses"
Write-Host "     from the 'Deployment Summary' printed above."
Write-Host ""
Write-Host "  2. Add them to web/.env.local:"
Write-Host "       NEXT_PUBLIC_VAULT_ARB_ONE=<LiquidityVault address>"
Write-Host "       NEXT_PUBLIC_HOOK_ARB_ONE=<DynamicFeeHook address>"
Write-Host "       NEXT_PUBLIC_DISTRIBUTOR_ARB_ONE=<FeeDistributor address>"
Write-Host ""
Write-Host "  3. Add the same vars to Vercel (Production) and redeploy the site."
Write-Host ""
Write-Host "  4. (Optional) Deploy BootstrapRewards, then call:"
Write-Host "       FeeDistributor.setTreasury(<BootstrapRewards address>)"
Write-Host "     to redirect the treasury share into the bonus program."
Write-Host ""
