# Relayer configuration

`docker-compose.yml` mounts this directory into the OpenZeppelin Relayer at `/app/config`. It is **empty on
purpose**: what belongs here is the relayer's signer configuration, and a signer is a key.

What the deployment has to put here (see the relayer's own documentation for the exact schema of the version
you run):

* **`config.json`** — the relayer definitions. One relayer, id `amps-keeper` (or whatever
  `AMPS_RELAYER_ID` says), network `robinhood` or `robinhood-testnet`, the RPC URL, and a policy: a gas-price
  cap, a whitelist of allowed `to` addresses (the vault, and nothing else — the keeper only ever calls
  `AmpsVault`), and the signer id below.
* **`signers/`** — the keystore. A local JSON keystore decrypted with `KEYSTORE_PASSPHRASE`, or, for anything
  holding real value, a reference to an HSM/KMS/Turnkey signer. The keeper never sees it.

The address of that signer is what `AMPS_SENDER_ADDRESS` must be set to: the keeper simulates every job as the
account that will send it, and a simulation run as the wrong account can succeed where the transaction fails.

Fund it with enough native ETH for gas. `docs/keeper-runbook.md` §7 covers what happens when it runs dry — the
short version is that the keeper cannot send, the watchdog stays tripped, and `KeeperSubmitErrors` pages.

Nothing in this directory is committed beyond this file; add `apps/keeper/relayer/config/*` to your deployment's
secret management, not to git.
