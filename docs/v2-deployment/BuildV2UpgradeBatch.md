# BuildV2UpgradeBatch configuration

Source: [BuildV2UpgradeBatch.s.sol](../../script/v2/BuildV2UpgradeBatch.s.sol).
Configuration: [UpgradeConfig.sol](../../script/v2/configs/UpgradeConfig.sol),
which inherits [SharedConfig.sol](../../script/v2/configs/SharedConfig.sol).
Shared release: [deployment configurations](../v2-deployment-configurations.md).

Use this after [DeployV2Dependencies](./DeployV2Dependencies.md) has deployed and
verified its contracts. This is a read-only builder: it validates production
bindings and generates the timelock calldata for both proxy upgrades in one batch.
Running it does not deploy, schedule, execute, or upgrade contracts.

Inputs below are Solidity constants in those configuration files. `TBD` means an unresolved
deployment output or launch decision; the current zero values and
`UPGRADE_CONFIGURATION_APPROVED = false` are placeholders, not approved launch settings.

## 1. Existing addresses already configured

These addresses are in `SharedConfig.sol`. User-confirmed addresses are identified
separately from source constants. Source constants must still be verified against
the intended production configuration.

| Constant | Currently configured address | Source / purpose |
|---|---|---|
| `STAKED_USDAT_PROXY` | `0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7` | User-confirmed; first upgrade target. |
| `WITHDRAWAL_QUEUE_PROXY` | `0x4Bc9FEC04F0F95e9b42a3EF18F3C96fB57923D2e` | User-confirmed; second upgrade target. |
| `USDAT` | `0x23238f20b894f29041f48D88eE91131C395Aaa71` | User-confirmed; queue implementation asset binding. |
| `TIMELOCK` | `0xfD5782E3BFF366601da3973aE30C583dE4F08A67` | Source constant; existing admin/upgrade timelock for both proxies. |
| `PROPOSER` | `0x610182581C93687Ca03F4a8E7f124f8cEC616820` | Source constant; scheduling account with the timelock's proposer role. |

## 2. Deployed dependency addresses

All five constants are populated in `UpgradeConfig.sol` from the supplied deployment
manifest. Deployment and Etherscan verification are user-confirmed.

| Constant to set | Value | Deployment output |
|---|---|---|
| `STAKED_USDAT_IMPLEMENTATION` | `0x188597b16D391cF7FB74b7f12e4f736B8a1B2516` | `deployed.stakedUsdatImplementation` |
| `WITHDRAWAL_QUEUE_IMPLEMENTATION` | `0x0Bb1Bcfb13987a647FE2f7db5f73C03F57696d73` | `deployed.withdrawalQueueImplementation` |
| `STRC_MIRROR_MODULE` | `0x5f860f46BEaA5A3fEE7726329a079243eCA4B5c1` | `deployed.strcMirrorModule` |
| `STRCON_MODULE` | `0x5f7bd5C95EE38706C4c4B609D44ABF63Ad8b2C4F` | `deployed.strconModule` |
| `EXECUTION_POLICY` | `0x30A8faEAd711d5c10285250d690B84caF50622A9` | `deployed.executionPolicy` |

The wrapper oracle and linked library addresses are already bound into these
deployments. This step needs no additional inputs for the wrapper, linked library,
STRCon token, price feeds, runtime hashes, or the deployer's nonce.

## 3. Wallet addresses

These addresses are user-provided and set in `UpgradeConfig.sol`. Confirm
eligibility, funding, allowances, and wallet controls using the runbook.

| Constant to set | Value | Purpose |
|---|---|---|
| `RECOVERY_ADDRESS` | `0x6e5301A99E321f535C9e077f8f7F98770229B1a4` | Canonical destination for seizures and token rescue; must satisfy vault restrictions. |
| `SURPLUS_SOURCE` | `0xbBeb892bAA398251EBe80809906F2Ae51EF5a783` | Dedicated USDat source wallet that preapproves the vault for surplus transfers. |
| `EXECUTION_VEHICLE` | `0xb3C29aa9196785F0aa5ECA6Cb0BcF1E92D83A468` | Trading counterparty and migration delivery wallet; initializes the execution policy. |

| Wallet controls to record | Value |
|---|---|
| Execution vehicle controlling wallet / signers / approval quorum | TBD |

## 4. Assign all twelve operational role addresses

Role holders are set in `UpgradeConfig.sol`. All twelve holders are user-provided below.
Enter the controlling timelock contract address for each timelocked role.
Record wallet controls or the governance reference for every holder.

| Constant to set | Holder address | Role / constraint | Controls / signers / quorum reference |
|---|---|---|---|
| `VAULT_PARAMETER_MANAGER` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | `PARAMETER_MANAGER_ROLE`; timelock required. | 2-day timelock (user-provided); controls TBD. |
| `VAULT_MARKET_MODE_MANAGER` | `0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92` | `MARKET_MODE_MANAGER_ROLE`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `VAULT_OPERATOR` | `0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92` | `OPERATOR_ROLE`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `VAULT_SURPLUS_MANAGER` | `0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92` | `SURPLUS_MANAGER_ROLE`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `VAULT_BLACKLISTER` | `0xf5a93281ac8604f99755cc489317e75aC334cfE2` | `BLACKLISTER_ROLE`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `VAULT_ENFORCER` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | `ENFORCER_ROLE`; timelock required. | 2-day timelock (user-provided); controls TBD. |
| `VAULT_PAUSER` | `0xf5a93281ac8604f99755cc489317e75aC334cfE2` | `PAUSER_ROLE`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `VAULT_UNPAUSER` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | `UNPAUSER_ROLE`; timelock required. | 2-day timelock (user-provided); controls TBD. |
| `QUEUE_OPERATOR` | `0xC35580434261f667d6abBDa9E3dC1DC31e5A1b92` | Queue `OPERATOR_ROLE`; matches `VAULT_OPERATOR`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `QUEUE_ENFORCER` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | Queue `ENFORCER_ROLE`; timelock required; matches `VAULT_ENFORCER`. | 2-day timelock (user-provided); controls TBD. |
| `QUEUE_PAUSER` | `0xf5a93281ac8604f99755cc489317e75aC334cfE2` | Queue `PAUSER_ROLE`; matches `VAULT_PAUSER`. | Fireblocks MPC wallet; approvers / approval quorum TBD. |
| `QUEUE_UNPAUSER` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | Queue `UNPAUSER_ROLE`; timelock required; matches `VAULT_UNPAUSER`. | 2-day timelock (user-provided); controls TBD. |

Per [specification §2.8](../saturn-v2-spec.md#28-roles), operator, market-mode
manager, and surplus manager may share one address in any combination. All other
cross-role co-location remains prohibited. Holding the same role on both proxies
is permitted. The builder checks nonzero role addresses but does not enforce
this separation or verify operational timelock controls.

Pending spec review: §2.8 currently prohibits both the shared
parameter-manager/enforcer/unpauser timelock and the shared blacklister/pauser wallet.

`DEFAULT_ADMIN_ROLE` is preserved, not supplied to either initializer. The builder
requires `TIMELOCK` to hold it on both proxies. Record the complete existing holder
sets and controls in the runbook; this check does not exclude additional admins.
The mirror, wrapper, module, and execution policy use the vault's authorization
registry and need no separate operational role address inputs here.

### Governance controls supporting those role assignments

The deployment script does not create governance timelocks. Identify and verify
these contracts before selecting the role addresses. Each column represents a
distinct role's timelock; record separate instances if vault and queue use
different holders for the same role. These records support configuration review
and are not extra arguments to `BuildV2UpgradeBatch`.

| Control | Admin / upgrade | Parameter manager | Enforcement | Unpause |
|---|---|---|---|---|
| Contract address | `TIMELOCK` above | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` | `0x6F72de4F529a03Bfa883825152656a8c62CBB626` |
| Contract version / source | TBD | TBD | TBD | TBD |
| Minimum delay, seconds | `432000` (script requires 5 days) | `172800` (user-provided; verify live) | `172800` (user-provided; verify live) | `172800` (user-provided; verify live) |
| Timelock admin holder(s) | TBD | TBD | TBD | TBD |
| Proposer address(es) | `PROPOSER` above required; complete set TBD | TBD | TBD | TBD |
| Executor address(es) / open execution | Open execution required via role grant to `address(0)`; complete set TBD | TBD | TBD | TBD |
| Canceller address(es) | TBD | TBD | TBD | TBD |
| Controlling wallet(s) / signers / approval quorum | TBD | TBD | TBD | TBD |
| Target contract(s) / granted role(s) | Both proxies / `DEFAULT_ADMIN_ROLE`; complete grants TBD | TBD | TBD | TBD |

## 5. Set the non-address inputs

Set these inputs in `UpgradeConfig.sol`. Zero fees or capacity can be deliberate
values, but their current zero constants are not a recorded approval. Review every
field before enabling the builder.
Basis points use `100 bps = 1%`; USDat amounts use 6 decimal places.

| Constant to set | Approved value | Current value / requirement |
|---|---|---|
| `BASE_REDEMPTION_FEE_BPS` | TBD | `0`; no greater than elevated redemption fee. |
| `ELEVATED_REDEMPTION_FEE_BPS` | TBD | `0`; at most `500` bps. |
| `ELEVATED_DEPOSIT_FEE_BPS` | TBD | `0`; at most `500` bps. |
| `EXECUTION_TOLERANCE_BPS` | TBD | `0`; at most `500` bps. |
| `MIGRATION_TOLERANCE_BPS` | TBD | `0`; at most `500` bps. |
| `INITIAL_EXECUTION_CAPACITY` | TBD | `0`; `uint128`, raw USDat units; initial available capacity also starts at this amount. |
| `INITIAL_EXECUTION_REFILL_PER_DAY` | TBD | `0`; `uint128`, raw USDat units per day. |
| `EXPECTED_SCHEDULE_TIMESTAMP` | TBD | `0`; must be nonzero Unix seconds. |
| `EXPECTED_UPGRADE_EXECUTION_TIMESTAMP` | TBD | `0`; at least schedule timestamp plus `432000` seconds. |
| `BATCH_SALT` | TBD | `bytes32(0)`; replace with a reviewed unique, nonzero `bytes32` salt. |
| `UPGRADE_CONFIGURATION_APPROVED` | TBD — enable after review | Currently `false`; `run()` requires `true`. |

`SharedConfig.sol` sets `EXPECTED_CHAIN_ID = 1`, `TIMELOCK_DELAY = 5 days`, and the
migration tolerance cap to `500` bps. `UpgradeConfig.sol` sets
`UPGRADE_PREDECESSOR = bytes32(0)` and fee/execution tolerance caps of `500` bps.
The expected timestamps are review inputs; they do not schedule transactions or
override the timelock's actual ready-at time.

The vault reads legacy seed accounting from preserved proxy storage during
initialization. No seed snapshot, vesting timestamp, or legacy queue inventory is
an initializer input. Those observations belong in the runbook.

## 6. Outputs and next step

The builder returns/logs the two proxy upgrade payloads, encoded initializers,
batch targets and ETH values, `scheduleCalldata`, `executeCalldata`, and
`operationId`. These are outputs to retain after running the builder, not fields
to supply beforehand. Both upgrades are encoded into the same atomic batch, with
the vault first and the queue second.

Use the [runbook](../v2-deployment-runbook.md) for rehearsal, submission, the delay,
execution evidence, and the validation round trip. After Step 1 and its validation
gate, use [BuildV2Migration](./BuildV2Migration.md) for the separate migration inputs.
