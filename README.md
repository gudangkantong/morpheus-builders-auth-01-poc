# BUILDERS-AUTH-01 — BuildersV4 subnet squat: unprivileged `claimAdmin` steals subnet rewards

Target: BuildersV4 `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9` on Base, fork pinned at block 55477144.

Setup: `forge install foundry-rs/forge-std` (once).

Run: `forge test -vv` (needs network access to `https://base-rpc.publicnode.com`).

Root cause: `createSubnet()` stores arbitrary `admin` / `claimAdmin` from calldata
and never checks `msg.sender` against either. `subnetCreationFeeAmount` is 0, so
squatting a name is free. `claim()` pays the subnet's accrued MOR rewards to
whoever holds `admin` or `claimAdmin`, to any `receiver_`.

Attack: attacker creates a subnet for a trusted project's not-yet-created name
with `admin` = the project and `claimAdmin` = attacker. Users deposit because the
stored admin is the trusted project. The attacker claims the reward stream until
the admin notices and calls `editSubnet` to remove them.

Tests:
- `testSubnetSquatClaimStealsRewards`: full attack, asserts attacker MOR balance grows.
- `testControlNonPrivilegedCannotClaim`: control showing the `claim` check exists
  but is satisfied by the squatted `claimAdmin` role.
