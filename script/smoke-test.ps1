# smoke-test.ps1
# Run after both DeployTokens.s.sol and Deploy.s.sol have broadcast.
# Usage: .\script\smoke-test.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 1. Load .env ──────────────────────────────────────────────────────────────
$envFile = Join-Path $PSScriptRoot ".." ".env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env not found. Copy .env.example → .env and fill in your values."
}

Get-Content $envFile | Where-Object { $_ -match "^\s*[^#]" -and $_ -match "=" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $val = $parts[1].Split("#")[0].Trim()  # strip inline comments
    [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $val, "Process")
}

# ── 2. Resolve required variables ─────────────────────────────────────────────
$rpc         = $env:ARBITRUM_TESTNET_RPC_URL
$privateKey  = $env:PRIVATE_KEY
$token0      = $env:TOKEN0
$vault       = $env:VAULT
$deposit     = "1000000"   # 1 USDC (6 decimals)

foreach ($var in @("ARBITRUM_TESTNET_RPC_URL","PRIVATE_KEY","TOKEN0","VAULT")) {
    if (-not [System.Environment]::GetEnvironmentVariable($var, "Process")) {
        Write-Error "Missing required .env variable: $var"
    }
}

# ── 3. Derive wallet address ───────────────────────────────────────────────────
Write-Host "`n--- Deriving wallet address ---"
$wallet = (cast wallet address --private-key $privateKey).Trim()
Write-Host "Wallet : $wallet"

# ── 4. Pre-flight balances ─────────────────────────────────────────────────────
Write-Host "`n--- Pre-flight balances ---"
$usdcBalance = (cast call $token0 "balanceOf(address)(uint256)" $wallet --rpc-url $rpc).Trim() -replace '\s*\[.*\]', ''
Write-Host "TOKEN0 balance (raw) : $usdcBalance"
if ([bigint]::Parse($usdcBalance) -lt [bigint]::Parse($deposit)) {
    Write-Error "Insufficient TOKEN0 balance. Need at least $deposit units (1 USDC)."
}

# ── 5. Approve ────────────────────────────────────────────────────────────────
Write-Host "`n--- Step 1: Approve vault to spend TOKEN0 ---"
$approveTx = cast send $token0 `
    "approve(address,uint256)" $vault $deposit `
    --rpc-url $rpc --private-key $privateKey
Write-Host "Approve tx: $approveTx"

# ── 6. Deposit ────────────────────────────────────────────────────────────────
Write-Host "`n--- Step 2: Deposit $deposit units into vault ---"
$depositTx = cast send $vault `
    "deposit(uint256,address)" $deposit $wallet `
    --rpc-url $rpc --private-key $privateKey
Write-Host "Deposit tx: $depositTx"

# ── 7. Verify shares received ─────────────────────────────────────────────────
Write-Host "`n--- Verification ---"
$shares = (cast call $vault "balanceOf(address)(uint256)" $wallet --rpc-url $rpc).Trim() -replace '\s*\[.*\]', ''
$assets = (cast call $vault "totalAssets()(uint256)" --rpc-url $rpc).Trim() -replace '\s*\[.*\]', ''
Write-Host "Vault shares held  : $shares"
Write-Host "Vault totalAssets  : $assets"

if ([bigint]::Parse($shares) -gt 0) {
    Write-Host "`n[PASS] Smoke test passed — shares minted and vault is live." -ForegroundColor Green
} else {
    Write-Error "[FAIL] Smoke test failed — no shares minted."
}
