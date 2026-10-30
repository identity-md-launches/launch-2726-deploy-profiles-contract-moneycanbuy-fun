// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Profiles} from "../../src/Profiles.sol";
import {TextRules} from "../../src/helpers/TextRules.sol";

/// @dev Only the delegate.xyz v2 entry points exercised by this integration test.
///      ABI source: https://github.com/delegatexyz/delegate-registry/blob/main/src/IDelegateRegistry.sol
interface IProfilesForkRegistry {
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function delegateContract(address to, address contract_, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function delegateERC721(address to, address contract_, uint256 tokenId, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}

/// @dev Mainnet fork (MAINNET_RPC_URL, skipped without it), pinned to block 26305652.
///      Checks the deployed TextRules helper, identity.md #827, and the real delegate.xyz v2 registry.
contract ProfilesForkTest is Test {
    address constant TEXT_RULES = 0xAdfe6bd2C17dB514241e1A9B3342F88876073B7F;
    address constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant DELEGATE = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant STRANGER = address(0x5791);

    Profiles profiles;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url, 26_305_652);
        assertEq(block.chainid, 1);
        assertEq(block.number, 26_305_652);
        assertGt(TEXT_RULES.code.length, 0);
        assertGt(DELEGATE.code.length, 0);
        assertGt(NFT.code.length, 0);
        profiles = new Profiles(TEXT_RULES, DELEGATE);
    }

    function _hosts() internal pure returns (string[25] memory) {
        return [
            "x.com",
            "twitter.com",
            "pbs.twimg.com",
            "youtube.com",
            "youtu.be",
            "tiktok.com",
            "instagram.com",
            "drive.google.com",
            "lh3.googleusercontent.com",
            "photos.google.com",
            "imgur.com",
            "i.imgur.com",
            "t.me",
            "ibb.co",
            "i.ibb.co",
            "reddit.com",
            "i.redd.it",
            "dropbox.com",
            "arweave.net",
            "etherscan.io",
            "sepolia.etherscan.io",
            "github.com",
            "kick.com",
            "twitch.tv",
            "clips.twitch.tv"
        ];
    }

    function test_Fork_DeployedTextRulesSameHosts() public {
        TextRules local = new TextRules();
        console.log("deployed TextRules code bytes", TEXT_RULES.code.length);
        console.log("local    TextRules code bytes", address(local).code.length);
        console.log("same runtime code", keccak256(TEXT_RULES.code) == keccak256(address(local).code));
        assertEq(TEXT_RULES.code, address(local).code, "deployed TextRules differs from supplied helper");
        string[25] memory hosts = _hosts();
        for (uint256 i; i < hosts.length; ++i) {
            string memory u = string.concat("https://", hosts[i], "/abc.png");
            TextRules(TEXT_RULES).checkScreenshotUrl(u); // reverts if the host is not listed
            local.checkScreenshotUrl(u);
        }
        string[8] memory bad = [
            "evil.com",
            "arweave.net.evil.com",
            "ipfs.io",
            "gateway.pinata.cloud",
            "nftstorage.link",
            "i.seadn.io",
            "moneycanbuy.fun",
            "ARWEAVE.NET"
        ];
        for (uint256 i; i < bad.length; ++i) {
            string memory u = string.concat("https://", bad[i], "/abc.png");
            vm.expectRevert(Profiles.HostNotAllowed.selector);
            TextRules(TEXT_RULES).checkScreenshotUrl(u);
        }
        bytes memory long = new bytes(301 - 20);
        for (uint256 i; i < long.length; ++i) {
            long[i] = "a";
        }
        vm.expectRevert(Profiles.BadEvidence.selector);
        TextRules(TEXT_RULES).checkScreenshotUrl(string.concat("https://arweave.net/", string(long)));
    }

    function test_Fork_Identity827() public {
        address holder = IERC721(NFT).ownerOf(827);
        console.log("identity.md #827 holder", holder);
        uint256 g = gasleft();
        IERC721(NFT).ownerOf(827);
        console.log("ownerOf(827) gas (warm)", g - gasleft());

        vm.prank(STRANGER);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("stranger", 1, NFT, 827, "");

        vm.prank(holder);
        profiles.set("alice", 1, NFT, 827, "");
        Profiles.ProfileView memory v = profiles.profileOf(holder);
        assertTrue(v.owned);
        assertEq(v.tokenId, 827);

        // sold -> no picture for the old holder, the name stays
        vm.prank(holder);
        IERC721(NFT).transferFrom(holder, STRANGER, 827);
        v = profiles.profileOf(holder);
        assertFalse(v.owned);
        assertEq(v.name, "alice");
        vm.prank(STRANGER);
        profiles.set("bob", 1, NFT, 827, "");
        assertTrue(profiles.profileOf(STRANGER).owned);
    }

    function test_Fork_LinkThroughDeployedTextRules() public {
        vm.startPrank(STRANGER);
        profiles.set("link_user", 3, address(0), 0, "https://arweave.net/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("link_user", 3, address(0), 0, "https://evil.com/x.png");
        vm.stopPrank();
        assertEq(profiles.profileOf(STRANGER).pic, 3);
    }

    function test_Fork_WalletDelegationGrantAndRevoke() public {
        _exerciseDelegation(0);
    }

    function test_Fork_ContractDelegationGrantAndRevoke() public {
        _exerciseDelegation(1);
    }

    function test_Fork_TokenDelegationGrantAndRevoke() public {
        _exerciseDelegation(2);
    }

    function _grant(address holder, address hot, uint8 scope, bool enabled) private {
        IProfilesForkRegistry registry = IProfilesForkRegistry(DELEGATE);
        vm.prank(holder);
        if (scope == 0) registry.delegateAll(hot, bytes32(0), enabled);
        else if (scope == 1) registry.delegateContract(hot, NFT, bytes32(0), enabled);
        else registry.delegateERC721(hot, NFT, 827, bytes32(0), enabled);
    }

    function _exerciseDelegation(uint8 scope) private {
        address holder = IERC721(NFT).ownerOf(827);
        address hot = makeAddr("Profiles fork delegated wallet");
        IProfilesForkRegistry registry = IProfilesForkRegistry(DELEGATE);
        assertFalse(registry.checkDelegateForERC721(hot, holder, NFT, 827, bytes32(0)));
        _expectNotOwner(hot);
        _grant(holder, hot, scope, true);
        assertTrue(registry.checkDelegateForERC721(hot, holder, NFT, 827, bytes32(0)));
        vm.prank(hot);
        profiles.set("delegated_user", 1, NFT, 827, "");
        Profiles.ProfileView memory beforeRecord = profiles.profileOf(hot);
        assertTrue(beforeRecord.owned, "real registry must fit CALL_GAS");
        assertEq(beforeRecord.nft, NFT);
        assertEq(beforeRecord.tokenId, 827);
        assertEq(beforeRecord.since, block.timestamp);

        _grant(holder, hot, scope, false);
        assertFalse(registry.checkDelegateForERC721(hot, holder, NFT, 827, bytes32(0)));
        assertFalse(profiles.profileOf(hot).owned);
        assertEq(profiles.ownerOfName("DELEGATED_USER"), hot);
        _expectNotOwner(hot);
        beforeRecord.owned = false;
        assertEq(abi.encode(profiles.profileOf(hot)), abi.encode(beforeRecord));

        _grant(holder, hot, scope, true);
        assertTrue(profiles.profileOf(hot).owned, "grant is reflected without calling set again");
        vm.prank(hot);
        profiles.clear();
        assertEq(profiles.ownerOfName("delegated_user"), address(0));
        assertEq(profiles.profileOf(hot).since, 0);
        assertTrue(registry.checkDelegateForERC721(hot, holder, NFT, 827, bytes32(0)));
    }

    function _expectNotOwner(address user) private {
        vm.prank(user);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("delegated_user", 1, NFT, 827, "");
    }

    function test_Fork_DelegationBindsOwnerCollectionTokenAndRights() public {
        address holder = IERC721(NFT).ownerOf(827);
        address hot = makeAddr("Profiles fork scoped delegate");
        address outsider = makeAddr("Profiles fork other delegator");
        IProfilesForkRegistry registry = IProfilesForkRegistry(DELEGATE);

        vm.prank(holder);
        registry.delegateERC721(hot, NFT, 828, bytes32(0), true);
        _expectNotOwner(hot);
        vm.prank(holder);
        registry.delegateContract(hot, TEXT_RULES, bytes32(0), true);
        _expectNotOwner(hot);
        vm.prank(outsider);
        registry.delegateAll(hot, bytes32(0), true);
        _expectNotOwner(hot);

        bytes32 limitedRights = keccak256("profile display only");
        vm.startPrank(holder);
        registry.delegateAll(hot, limitedRights, true);
        registry.delegateContract(hot, NFT, limitedRights, true);
        registry.delegateERC721(hot, NFT, 827, limitedRights, true);
        vm.stopPrank();
        assertTrue(registry.checkDelegateForERC721(hot, holder, NFT, 827, limitedRights));
        assertFalse(registry.checkDelegateForERC721(hot, holder, NFT, 827, bytes32(0)));
        _expectNotOwner(hot);

        _grant(holder, hot, 2, true);
        vm.prank(hot);
        profiles.set("delegated_user", 1, NFT, 827, "");
        assertTrue(profiles.profileOf(hot).owned);
    }

    function test_Fork_SaleRequiresDelegationFromTheNewOwner() public {
        address holder = IERC721(NFT).ownerOf(827);
        address buyer = makeAddr("Profiles fork buyer");
        address hot = makeAddr("Profiles fork sale delegate");
        _grant(holder, hot, 2, true);
        vm.prank(hot);
        profiles.set("delegated_user", 1, NFT, 827, "");
        assertTrue(profiles.profileOf(hot).owned);
        vm.prank(holder);
        IERC721(NFT).transferFrom(holder, buyer, 827);
        assertFalse(profiles.profileOf(hot).owned);
        _expectNotOwner(hot);
        assertEq(profiles.ownerOfName("delegated_user"), hot);
        _grant(buyer, hot, 1, true);
        assertTrue(profiles.profileOf(hot).owned);
        _grant(holder, hot, 2, false);
        assertTrue(profiles.profileOf(hot).owned, "former owner's revocation is irrelevant");
        _grant(buyer, hot, 1, false);
        assertFalse(profiles.profileOf(hot).owned);
    }

    function test_Fork_NftApprovalsDoNotAuthorizePictures() public {
        address holder = IERC721(NFT).ownerOf(827);
        address hot = makeAddr("Profiles fork approved operator");
        vm.prank(holder);
        IERC721(NFT).approve(hot, 827);
        _expectNotOwner(hot);
        vm.prank(holder);
        IERC721(NFT).setApprovalForAll(hot, true);
        _expectNotOwner(hot);
        assertEq(profiles.ownerOfName("delegated_user"), address(0));
    }

    function test_Fork_LinkErrorsPreservePreviousProfile() public {
        address user = makeAddr("Profiles fork link boundary");
        bytes memory url = new bytes(300);
        bytes memory prefix = bytes("https://arweave.net/");
        for (uint256 i; i < url.length; ++i) {
            url[i] = i < prefix.length ? prefix[i] : bytes1("a");
        }
        vm.prank(user);
        profiles.set("boundary_user", 3, address(0), 0, string(url));
        bytes memory beforeRecord = abi.encode(profiles.profileOf(user));
        vm.startPrank(user);
        vm.expectRevert(Profiles.BadEvidence.selector);
        profiles.set("new_name", 3, address(0), 0, string.concat(string(url), "a"));
        vm.expectRevert(Profiles.BadEvidence.selector);
        profiles.set("new_name", 3, address(0), 0, "https://arweave.net/a\\b");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("new_name", 3, address(0), 0, "https://arweave.net@evil.example/image");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("new_name", 3, address(0), 0, "https://arweave.net:443/image");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("new_name", 3, address(0), 0, "https://www.mobile.arweave.net/image");
        vm.stopPrank();
        assertEq(abi.encode(profiles.profileOf(user)), beforeRecord);
        assertEq(profiles.ownerOfName("boundary_user"), user);
        assertEq(profiles.ownerOfName("new_name"), address(0));
    }
}
