// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Profiles} from "../../src/Profiles.sol";
import {TextRules} from "../../src/helpers/TextRules.sol";

/// @dev Mainnet fork (FORK_URL, skipped without it): the deployed TextRules (immutable of the live CaseDesk
///      0xE4d4…5b57) has checkScreenshotUrl with the same host list as src/helpers/TextRules.sol, and a profile with
///      identity.md #827 works against the real NFT and the real delegate.xyz v2 registry.
contract ProfilesForkTest is Test {
    address constant TEXT_RULES = 0xAdfe6bd2C17dB514241e1A9B3342F88876073B7F;
    address constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant DELEGATE = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant STRANGER = address(0x5791);

    Profiles profiles;

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
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
}
