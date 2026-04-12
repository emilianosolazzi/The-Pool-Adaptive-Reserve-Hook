# The Pool

## Security

### Internal Audit Status: Complete

All critical paths have undergone full internal review with emphasis on deterministic correctness, precision, and invariant preservation.

**Scope:**

- Fee calculation across boundary conditions (min / median / max swap sizes)
- FeeDistributor split (33/67) with exact rounding behavior validation
- `donate()` accounting integrity via poolManager
- ERC-4626 share price invariance across deposit / withdraw / yield cycles
- Reentrancy analysis on all state-mutating entry points
- Transient storage slot collision analysis (EVM-level safety)
- Hook flag validation at deployment (static + runtime assumptions)

**Testing:**

- 100% function coverage
- Full integration path validated: `deposit → swap → fee → distribute → donate → withdraw`
- All invariants hold under simulation.

### External Audit

Scheduled at $100K TVL.

The system is independently built and self-funded. Capital is allocated to security when it becomes economically rational — not performative.

### Verification Model

- Code is public
- Tests are reproducible
- Math is inspectable in minutes

No trust assumptions are required beyond what can be verified directly.
