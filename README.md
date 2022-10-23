# Swivel contest details

- 50,000 USDC main award pot
- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)
- Starts October 24, 2022 15:00 UTC
- Ends November 7, 2022 15:00 UTC

# Resources

- [Website](https://swivel.finance/)
- [Twitter](https://twitter.com/SwivelFinance)

# Audit scope

~ 1666 nSLOC

TBD

# About Swivel

TBD

## Building

To build the project, install Foundry.

Then, from the root of the project, run `forge build`.

## Testing

To run the tests, use the following command:

`forge test --fork-url ${RPC_URL} --fork-block-number ${BLOCK_NUMBER} --use solc:0.8.16 --via-ir --no-match-test "Skip\(\B"`

Note that we use fork-mode tests. As a result, you will need to set `RPC_URL` to run those tests.

The provided command will skip tests ending with "Skip". One test in the suite, `testSwivelLend` was skipped due to issues found in Foundry associated with partially verified ERC20 contracts.
