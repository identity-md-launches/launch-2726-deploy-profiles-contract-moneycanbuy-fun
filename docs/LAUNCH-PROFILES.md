# Launch text for the IMD swarm: Profiles

`src/Profiles.sol`, a display name and a picture per wallet, is its own `evm_contracts` launch: one contract with two
address constructor arguments, deployed in one transaction through the IMD ProjectFactory (`0xfF03…7120`), 0.5 IMD.
No core contract reads it and it reads no core contract. Its constructor takes the TextRules helper on Ethereum
mainnet (`0xAdfe6bd2C17dB514241e1A9B3342F88876073B7F`, the runtime code of `src/helpers/TextRules.sol`) and the
delegate.xyz v2 registry (`0x00000000000000447e69651d841bD8D104Bed493`). Runtime 5,489 bytes (`forge build --sizes`).
Its tests: `test/Profiles.t.sol` (34 tests) and `test/fork/ProfilesFork.t.sol` (mainnet fork, `FORK_URL`),
`forge test` runs 743.

## Launch text (`evm_contracts`, Profiles)

```
Deploy the profiles contract of moneycanbuy.fun as it is: Profiles, an evm_contracts launch from this repository on Ethereum mainnet (no token), one contract. No core contract reads it and it reads no core contract; it calls two Ethereum mainnet contracts given to its constructor.

Contracts, in this order:
1. Profiles, constructorArgs ["0xAdfe6bd2C17dB514241e1A9B3342F88876073B7F", "0x00000000000000447e69651d841bD8D104Bed493"]

The first argument is textRules: the TextRules helper of moneycanbuy.fun on Ethereum mainnet (its runtime code is src/helpers/TextRules.sol of this repository); Profiles calls only its pure checkScreenshotUrl(string). The second is delegateRegistry: the delegate.xyz v2 registry; Profiles calls only checkDelegateForERC721(address,address,address,uint256,bytes32).

Profiles keeps one display name and one picture per wallet. set(name, pic, nft, tokenId, link) replaces the caller's whole record and emits ProfileSet; clear() erases it, frees its name at once and emits ProfileCleared. A name is 3..20 bytes of A-Z a-z 0-9 _, not starting with 0x or 0X, otherwise BadName. Names are unique by skeleton: lower case, _ dropped, 0 becomes o, 1 and i become l; the skeleton has at least 3 characters (BadName), a skeleton held by another wallet reverts NameTaken. These 17 skeletons are reserved for nobody and revert NameReserved, compared as whole skeletons only (a name that merely contains one is allowed): moneycanbuy, moneycanbuyfun, mcb, lmd, lmdfun, swarm, yolo, admln, offlclal, support, team, treasury, oracle, mod, moderator, system, deployer. The name may be empty when there is a picture; name and picture both empty reverts BadName. pic 0 none (nft, tokenId and link empty); pic 1 an ERC-721 and pic 2 an ERC-1155 token (link empty, nft must answer supportsInterface 0x80ac58cd or 0xd9b67a26, the caller must hold tokenId now, for ERC-721 also through a delegate.xyz v2 delegation, otherwise NotNftOwner); pic 3 an https link (nft and tokenId zero) accepted by textRules.checkScreenshotUrl, whose errors HostNotAllowed and BadEvidence pass through unchanged; anything else BadPicture. Every call to a token contract or the registry is a STATICCALL capped at CALL_GAS = 30000 gas that reads 32 bytes; a failure counts as not owned. profileOf(user) returns (name, pic, nft, tokenId, link, owned, since) with owned re-checked on every read (true for a link, false for none); profilesOf(users) returns one per address; ownerOfName(name) returns the wallet holding that skeleton, address(0) when free or invalid. Hiding a profile is not part of this contract: the site's hide list HiddenList takes (the Profiles address, 3, the wallet as uint160) like any other item.

Fixed parameters, fail, don't change: the two constructor arguments above, in this order; the name rules, the skeleton mapping and exactly the 17 reserved skeletons above, none added or removed and no substring match; PIC_NONE() = 0, PIC_ERC721() = 1, PIC_ERC1155() = 2, PIC_LINK() = 3, CALL_GAS() = 30000; the functions set(string,uint8,address,uint256,string), clear(), profileOf(address), profilesOf(address[]), ownerOfName(string), nameOwner(bytes20), textRules(), delegateRegistry(), with the return tuple of profileOf in the order above; the events ProfileSet(address indexed user, string name, uint8 pic, address nft, uint256 tokenId, string link) and ProfileCleared(address indexed user); the errors BadName(), NameTaken(), NameReserved(), BadPicture(), NotNftOwner(), ZeroAddress(), HostNotAllowed(), BadEvidence(). The site decodes exactly these; if a reproduced finding would need any of them changed, fail the job instead of changing it.

Profiles has no owner, no admin, no role, no pause and no upgrade path; no payable function, no receive or fallback, no token transfer; it holds no money. The constructor only stores the two addresses (textRules must not be zero, ZeroAddress).

Known limitations (accepted rules, not findings): anyone may set a profile, gas is the only cost and a free name goes to the first wallet that takes it; a name stays with its wallet when the picture token is sold, only owned turns false; the picture token is any contract that answers the checks, a token contract that reverts, burns gas or returns a large payload only makes its own owned false; the link is checked by host and length only, not by content; names are not filtered beyond the charset, the skeleton and the reserved list.

The tests must keep passing: forge test (743 tests), of them 34 in test/Profiles.t.sol for this contract; test/fork/ProfilesFork.t.sol runs against the two constructor contracts on a mainnet fork (FORK_URL).

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the fixed parameters above, and do not add an owner, a pause, an upgrade path, a fee, a payable function or a token transfer.
Known limitations listed in docs are accepted rules, not findings; do not change them.
```

## Known limitations

- Anyone may set a profile; gas is the only cost and a free name goes to the first wallet that takes it.
- A name stays with its wallet when the picture token is sold; only `owned` turns false.
- The picture token is any contract that answers the checks; a token contract that reverts, burns gas or returns a
  large payload only makes its own `owned` false.
- The link is checked by host and length only (TextRules `checkScreenshotUrl`), not by content.
- Names are not filtered beyond the charset, the skeleton and the 17 reserved skeletons; the site hides a profile
  through `HiddenList` with the key (the Profiles address, 3, the wallet as uint160).
