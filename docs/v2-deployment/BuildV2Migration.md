# Migration configuration and commands

[BuildV2Migration.s.sol](../../script/v2/migrate/BuildV2Migration.s.sol) checks
readiness and builds the `migrate(expectedStrcon, deadline)` operation.

## Inputs to finalize

Set these in [MigrationConfig.sol](../../script/v2/configs/MigrationConfig.sol):

| Parameter | Value to set | Requirement |
|---|---|---|
| `EXPECTED_STRCON` | TBD | Exact STRCon delivery × `10^18`; must be nonzero. |
| `MIGRATION_DEADLINE` | TBD | Unix expiry timestamp later than scheduling time + two days. Allow time to execute. |
| `MIGRATION_CONFIGURATION_APPROVED` | `true` | Enable scheduling and execution once the inputs are final. |

## Configured values

Migration settings are in `MigrationConfig.sol`; shared chain, token, and proxy
settings are in [SharedConfig.sol](../../script/v2/configs/SharedConfig.sol).

| Parameter | Value | Purpose |
|---|---|---|
| `EXPECTED_CHAIN_ID` | `1` | Ethereum mainnet. |
| `STAKED_USDAT_PROXY` | `0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7` | Vault receiving the STRCon; must already run v2. |
| `STRCON` | `0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c` | Token delivered to the vault. |
| `MIGRATION_TIMELOCK` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | Calls `migrate` on the vault. |
| `MIGRATION_PROPOSER` | `0x7A5A4064005584bc727666ec82548A9139d5F21e` | Configured Fireblocks proposer. Make selects the sender from the environment variable of the same name. |
| `MIGRATION_TIMELOCK_DELAY` | `2 days` | Wait between scheduling and execution. |
| `EXPECTED_EXECUTION_VEHICLE` | `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468` | Wallet supplying the STRCon. |
| `EXPECTED_MIGRATION_TOLERANCE_BPS` | `200` (2%) | Must match the vault's current migration tolerance. |
| `MAX_MIGRATION_TOLERANCE_BPS` | `500` (5%) | Maximum permitted tolerance. |
| `MIGRATION_PREDECESSOR` | `bytes32(0)` | No preceding timelock operation required. |
| `MIGRATION_SALT` | `bytes32(0)` | Zero is allowed. |

## Automatic checks

The scripts read the mirror, STRCon module, and execution policy from the vault.
Before scheduling and execution, they check:

- The timelock holds the vault's `PARAMETER_MANAGER_ROLE`, has a two-day minimum
  delay, and permits open execution.
- The vault is unpaused and the module/policy bindings are correct.
- The mirror is seeded, not retired, and fully vested; recognized STRCon module
  balance is zero.
- The execution vehicle and migration tolerance match the configured values.
- The vehicle holds at least `EXPECTED_STRCON` and has approved the vault to pull it.
- Prices are available, vault NAV and mirror value are nonzero, and the absolute
  projected whole-vault NAV change is at most 2%.

Scheduling also checks that the signing wallet holds `PROPOSER_ROLE` on the timelock.

```text
Scheduling: deadline > current timestamp + 2 days
Execution:  current timestamp <= original deadline
```

## Commands

Schedule through Fireblocks:

```bash
make migrate-schedule-dry-run
make migrate-schedule
```

After the two-day delay, execute with the deployer key before the deadline:

```bash
make migrate-execute-dry-run
make migrate-execute
```

The dry-run commands do not broadcast. Scheduling reports the operation's ready-at
time; execution requires it to be ready and confirms completion.

Keep the configuration unchanged after scheduling. Changing the amount, deadline,
predecessor, or salt requires a new proposal and delay.
