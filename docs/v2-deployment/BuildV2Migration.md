# BuildV2Migration inputs

Source: [BuildV2Migration.s.sol](../../script/v2/migrate/BuildV2Migration.s.sol).
Configuration: [MigrationConfig.sol](../../script/v2/configs/MigrationConfig.sol),
which inherits [SharedConfig.sol](../../script/v2/configs/SharedConfig.sol).
Run this after the [upgrade batch](./BuildV2UpgradeBatch.md) has executed and the
validation buy/sell round trip has completed. It validates live migration readiness
and generates the timelock transactions for `migrate(expectedStrcon, deadline)`.
The builder deploys no contracts and broadcasts no transactions. The
[schedule script](../../script/v2/migrate/ScheduleV2Migration.s.sol) and
[execute script](../../script/v2/migrate/ExecuteV2Migration.s.sol) use the same
configuration to submit and verify the operation through the Make targets below.

The values below are Solidity constants in those configuration files, not environment-variable
inputs. Complete the remaining inputs after validation, review them, and then set
`MIGRATION_CONFIGURATION_APPROVED = true` before running `run()`.

## Existing addresses in SharedConfig.sol

| Constant | Address | Status / required binding |
|---|---|---|
| `STAKED_USDAT_PROXY` | `0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7` | User-confirmed existing vault proxy; must already run v2. |
| `TIMELOCK` | `0xfD5782E3BFF366601da3973aE30C583dE4F08A67` | Configured address; verify the intended admin timelock and its live controls. |
| `STRCON` | `0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c` | Configured token address; must equal the active STRCon module's `ASSET()`. |

The timelock must hold the vault's `DEFAULT_ADMIN_ROLE`. The script also requires
an open executor role: `TIMELOCK.hasRole(EXECUTOR_ROLE, address(0)) == true`.
Scheduling requires the Fireblocks sender supplied as `ADMIN` to hold
`PROPOSER_ROLE` on `TIMELOCK`. Execution uses `PRIVATE_KEY` with the open executor
role. The deployer wallet and its nonce are not inputs to this builder.

## Execution vehicle in MigrationConfig.sol

| Constant | Value | What to supply |
|---|---|---|
| `EXPECTED_EXECUTION_VEHICLE` | `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468` | User-confirmed delivery wallet. Must exactly match `vault.executionPolicy().executionVehicle()`. |

This is a check against the live vehicle, not a request to deploy or change it.
The vehicle must hold the full `EXPECTED_STRCON` and approve that amount of STRCon
to the vault proxy above. The vault pulls the tokens during migration.

## Remaining operation inputs in MigrationConfig.sol

| Constant | Value | Requirement |
|---|---|---|
| `EXPECTED_STRCON` | TBD | Exact delivery amount in 18-decimal STRCon units; must be nonzero. Current placeholder: `0`. |
| `EXPECTED_MIGRATION_TOLERANCE_BPS` | 200 bps (2%) | Must match the vault's live `migrationToleranceBps()` and be at most `500` bps. Current literal: `200`. |
| `MIGRATION_DEADLINE` | TBD | Unix timestamp strictly later than the current block timestamp plus five days when building or scheduling. Execution requires the current timestamp to be at or before this original deadline. Allow time for scheduling and execution. Current placeholder: `0`. |
| `MIGRATION_SALT` | `bytes32(0)` | Zero is allowed; use the same salt when scheduling and executing. |
| `MIGRATION_CONFIGURATION_APPROVED` | TBD | Set to `true` after reviewing the completed configuration. Currently `false`, which blocks `run()`. |

The tolerance constant checks an existing vault setting; the generated migration
call does not change that setting. Only the amount and deadline are arguments to
`migrate`. The vehicle is read by the vault from its live execution policy.

## Fixed configuration settings

| Constant | Configuration file | Current value | Meaning |
|---|---|---|---|
| `EXPECTED_CHAIN_ID` | `SharedConfig.sol` | `1` | Ethereum mainnet. |
| `TIMELOCK_DELAY` | `SharedConfig.sol` | `5 days` / `432000` seconds | Must exactly match `TIMELOCK.getMinDelay()`. |
| `MAX_MIGRATION_TOLERANCE_BPS` | `SharedConfig.sol` | `500` | Maximum allowed tolerance, equal to 5%. |
| `MIGRATION_PREDECESSOR` | `MigrationConfig.sol` | `bytes32(0)` | No on-chain predecessor operation; completion of the validation gate is an operational prerequisite. |

## Addresses discovered automatically

| Address | Read from | Requirement |
|---|---|---|
| STRCMirrorModule | `vault.strcMirrorModule()` | Bound to this vault; seeded, not retired, and fully vested. |
| STRConModule | `vault.strconModule()` | Bound to this vault and `STRCON`; recognized `balance()` must be zero. |
| STRConExecutionPolicy | `vault.executionPolicy()` | Bound to this vault and the live STRCon module. |

Do not enter new module or policy addresses here. The builder uses the addresses
already installed by the v2 upgrade. Oracle addresses are reached through those
modules when reading prices; they are not migration-builder inputs.

## Conditions before building and executing

- Finish the validation round trip and return recognized STRCon balance to zero.
- Keep the vault unpaused. Stop legacy reward transfers and wait until the seeded,
  unretired mirror reports `getUnvestedAmount() == 0`.
- Confirm the active vehicle and migration tolerance match the configured values.
- Fund the vehicle with the full delivery and approve the vault to pull it.
- Confirm both positions price successfully. The builder requires nonzero vault
  NAV and mirror value, and the projected whole-vault NAV change must fit the
  configured tolerance.
- Recheck live readiness after the timelock delay, before execution. Prices,
  funding, allowances, and vehicle can change after scheduling. The execution
  script rechecks live readiness against the unchanged configuration and
  original deadline; it does not require another five days before that deadline.

Full sequencing and post-execution evidence, including permanent mirror retirement,
belong in the [deployment runbook](../v2-deployment-runbook.md).

## Schedule and execute

The targets run `source syncprod`. Set `RPC_URL` to an Ethereum mainnet RPC
endpoint, `ADMIN` to the Fireblocks proposer address, and `PRIVATE_KEY` to the
execution key, alongside the existing Fireblocks client settings.

```bash
make migrate-schedule-dry-run
make migrate-schedule
```

The scheduling dry run uses the regular RPC and makes no Fireblocks signing
request. Scheduling submits through Fireblocks with zero ETH, then independently
checks the on-chain operation and reports its ready-at time. Record the operation
ID, transaction hash, and ready-at time.

After the five-day delay, while the original deadline has not expired:

```bash
make migrate-execute-dry-run
make migrate-execute
```

Execution uses `RPC_URL` and `PRIVATE_KEY`. Both execution commands revalidate
live migration readiness and require the exact configured operation to be ready
on the timelock. Unscheduled, waiting, or completed operations are refused.
The broadcast target then independently checks that the matching timelock
operation is complete. Save the execution transaction hash and verify the
postconditions in the deployment runbook.

Keep the reviewed configuration unchanged after scheduling, including the exact
delivery amount, deadline, predecessor, and salt. A changed operation requires
a new proposal and delay. The scripts generate matching calldata directly;
no payload files or manual copying are needed.

## Optional read-only inspection

To inspect the migration payload, operation ID, and timelock calldata before
scheduling:

```bash
forge script script/v2/migrate/BuildV2Migration.s.sol:BuildV2Migration --rpc-url "$RPC_URL"
```

This builder applies the scheduling deadline check. Use
`make migrate-execute-dry-run` for simulation after the timelock delay.
For the reviewed baseline, see the [deployment runbook](../v2-deployment-runbook.md).
