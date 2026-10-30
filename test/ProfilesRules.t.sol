// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Profiles} from "src/Profiles.sol";
import {TextRules} from "src/helpers/TextRules.sol";

contract ProfilesRulesTest is Test {
    Profiles private profiles;
    address private alice;
    address private bob;
    string private constant LINK = "https://arweave.net/avatar";

    function setUp() public {
        profiles = new Profiles(address(new TextRules()), address(0));
        alice = makeAddr("rules alice");
        bob = makeAddr("rules bob");
        vm.warp(1_800_000_000);
    }

    function _setName(address user, string memory name) private {
        vm.prank(user);
        profiles.set(name, 0, address(0), 0, "");
    }

    function _rejectName(string memory name, bytes4 errorSelector) private {
        bytes memory beforeRecord = abi.encode(profiles.profileOf(alice));
        vm.prank(alice);
        vm.expectRevert(errorSelector);
        profiles.set(name, 0, address(0), 0, "");
        assertEq(abi.encode(profiles.profileOf(alice)), beforeRecord);
    }

    function test_ByteAndSkeletonLengthBoundaries() public {
        string[10] memory invalid =
            ["", "a", "ab", "___", "_a_", "_ab", "a_b", "a__________________b", "abcdefghijklmnopqrstu", "0Xq"];
        _setName(alice, "initial");
        for (uint256 i; i < invalid.length; ++i) {
            _rejectName(invalid[i], Profiles.BadName.selector);
            assertEq(profiles.ownerOfName(invalid[i]), address(0));
        }
        string[7] memory valid =
            ["abc", "_a_b_c_", "a_________________bc", "abcdefghijklmnopqrs", "abcdefghijklmnopqrst", "x0x", "_0xq"];
        for (uint256 i; i < valid.length; ++i) {
            _setName(alice, valid[i]);
            assertEq(profiles.profileOf(alice).name, valid[i]);
            assertEq(profiles.ownerOfName(valid[i]), alice);
        }
        // A longer input whose first 20 bytes are a held name must not alias that name.
        _setName(alice, "abcdefghijklmnopqrst");
        assertEq(profiles.ownerOfName("abcdefghijklmnopqrstu"), address(0));
        assertEq(profiles.ownerOfName("abcdefghijklmnopqrst_"), address(0));
    }

    function test_EveryByteClassInAName() public {
        bytes memory allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
        for (uint256 value; value < 256; ++value) {
            bool accepted;
            for (uint256 i; i < allowed.length; ++i) {
                if (bytes1(uint8(value)) == allowed[i]) accepted = true;
            }
            string memory candidate = string(abi.encodePacked("qz", bytes1(uint8(value)), "r"));
            if (accepted) {
                _setName(alice, candidate);
                assertEq(profiles.profileOf(alice).name, candidate);
                assertEq(profiles.ownerOfName(candidate), alice);
            } else {
                _rejectName(candidate, Profiles.BadName.selector);
                assertEq(profiles.ownerOfName(candidate), address(0));
            }
        }
    }

    function test_AllReservedSkeletonsAreWholeWordsOnly() public {
        string[17] memory reserved = [
            "moneycanbuy",
            "moneycanbuyfun",
            "mcb",
            "lmd",
            "lmdfun",
            "swarm",
            "yolo",
            "admln",
            "offlclal",
            "support",
            "team",
            "treasury",
            "oracle",
            "mod",
            "moderator",
            "system",
            "deployer"
        ];
        _setName(alice, "initial");
        for (uint256 i; i < reserved.length; ++i) {
            _rejectName(reserved[i], Profiles.NameReserved.selector);
            string memory variant = string.concat("_", _alias(bytes(reserved[i])), "_");
            _rejectName(variant, Profiles.NameReserved.selector);
            assertEq(profiles.ownerOfName(variant), address(0));
            assertEq(profiles.nameOwner(bytes20(bytes(reserved[i]))), address(0));
            _setName(alice, string.concat("q", reserved[i]));
            _setName(bob, string.concat(reserved[i], "q"));
            assertEq(profiles.ownerOfName(string.concat("q", reserved[i])), alice);
            assertEq(profiles.ownerOfName(string.concat(reserved[i], "q")), bob);
        }
        // Names outside the specified list are not an occasion to add policy.
        _setName(alice, "owner");
        _setName(alice, "root");
        _setName(alice, "null");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FullWidthNamesRoundTripAndRelease(bytes32 entropy, uint8 lengthSeed) public {
        uint256 length = bound(lengthSeed, 3, 20);
        bytes memory canonical = new bytes(length);
        bytes memory alphabet = "abcdefghjklmnopqrstuvwxyz23456789";
        canonical[0] = "q";
        canonical[1] = "z";
        for (uint256 i = 2; i < length; ++i) {
            canonical[i] = alphabet[uint8(entropy[i]) % alphabet.length];
        }
        bytes20 key = bytes20(canonical);
        string memory variant = _alias(canonical);
        _setName(alice, string(canonical));
        assertEq(profiles.nameOwner(key), alice);
        vm.prank(bob);
        vm.expectRevert(Profiles.NameTaken.selector);
        profiles.set(variant, 0, address(0), 0, "");
        vm.warp(1_800_001_000);
        _setName(alice, variant);
        assertEq(profiles.profileOf(alice).name, variant);
        assertEq(profiles.profileOf(alice).since, 1_800_000_000);
        assertEq(profiles.ownerOfName(string(canonical)), alice);
        vm.prank(alice);
        profiles.clear();
        assertEq(profiles.nameOwner(key), address(0));
        _setName(bob, string(canonical));
        assertEq(profiles.ownerOfName(variant), bob);
        assertEq(profiles.profileOf(bob).since, 1_800_001_000);
    }

    function _alias(bytes memory canonical) private pure returns (string memory) {
        bytes memory result = new bytes(canonical.length);
        for (uint256 i; i < canonical.length; ++i) {
            bytes1 c = canonical[i];
            if (c == "l") result[i] = "I";
            else if (c == "o") result[i] = "0";
            else if (c >= "a" && c <= "z") result[i] = bytes1(uint8(c) - 32);
            else result[i] = c;
        }
        return string(result);
    }

    function test_ForbiddenPrefixDependsOnRawSpelling() public {
        _setName(alice, "oxq");
        _rejectName("0xq", Profiles.BadName.selector);
        _rejectName("0Xq", Profiles.BadName.selector);
        assertEq(profiles.ownerOfName("0xq"), address(0));
        assertEq(profiles.ownerOfName("0Xq"), address(0));
        assertEq(profiles.ownerOfName("_0xq"), alice);
        vm.prank(bob);
        vm.expectRevert(Profiles.NameTaken.selector);
        profiles.set("_0xq", 0, address(0), 0, "");
        _setName(alice, "_0xq");
        vm.prank(alice);
        profiles.clear();
        assertEq(profiles.nameOwner(bytes20("oxq")), address(0));
    }

    function test_LinksRejectHostConfusionAndBubbleExactErrors() public {
        string[16] memory invalid = [
            "http://arweave.net/a",
            "HTTPS://arweave.net/a",
            "//arweave.net/a",
            "https://",
            "https://www.",
            "https://mobile.",
            "https://m.",
            "https://arweave.net.evil.example/a",
            "https://arweave.net@evil.example/a",
            "https://evil.example@arweave.net/a",
            "https://arweave.net:443/a",
            "https://ARWEAVE.NET/a",
            "https://arweave.net./a",
            "https://www.www.arweave.net/a",
            "https://mobile.m.arweave.net/a",
            "https://notarweave.net/a"
        ];
        vm.prank(alice);
        profiles.set("initial", 3, address(0), 0, LINK);
        for (uint256 i; i < invalid.length; ++i) {
            _rejectLink(invalid[i], Profiles.HostNotAllowed.selector);
        }
        assertEq(profiles.ownerOfName("initial"), alice);
        assertEq(profiles.ownerOfName("replacement"), address(0));
    }

    function test_LinkPrefixesAndSeparatorsAreAccepted() public {
        string[4] memory prefixes = ["", "www.", "m.", "mobile."];
        string[4] memory tails = ["", "/avatar", "?image=1", "#avatar"];
        for (uint256 i; i < prefixes.length; ++i) {
            for (uint256 j; j < tails.length; ++j) {
                string memory link = string.concat("https://", prefixes[i], "arweave.net", tails[j]);
                vm.prank(alice);
                profiles.set("", 3, address(0), 0, link);
                Profiles.ProfileView memory v = profiles.profileOf(alice);
                assertTrue(v.owned);
                assertEq(v.name, "");
                assertEq(v.link, link);
                assertEq(v.nft, address(0));
                assertEq(v.tokenId, 0);
            }
        }
    }

    function test_EveryLinkTailByte() public {
        vm.prank(alice);
        profiles.set("initial", 3, address(0), 0, LINK);
        for (uint256 value; value < 256; ++value) {
            string memory url = string(abi.encodePacked(LINK, bytes1(uint8(value))));
            // Published link-character grammar, independent of TextRules' implementation.
            bool allowed =
                value >= 33 && value <= 126 && value != 34 && value != 39 && value != 60 && value != 62 && value != 92;
            if (allowed) {
                vm.prank(alice);
                profiles.set("initial", 3, address(0), 0, url);
                assertEq(profiles.profileOf(alice).link, url);
            } else {
                _rejectLink(url, Profiles.BadEvidence.selector);
            }
        }
    }

    function test_UrlLengthAndStorageBoundaries() public {
        uint256[6] memory lengths = [uint256(30), 31, 32, 33, 299, 300];
        for (uint256 i; i < lengths.length; ++i) {
            string memory link = _url(lengths[i]);
            vm.prank(alice);
            profiles.set("initial", 3, address(0), 0, link);
            assertEq(profiles.profileOf(alice).link, link);
        }
        _rejectLink(_url(301), Profiles.BadEvidence.selector);
        _rejectLink(_url(512), Profiles.BadEvidence.selector);
        _rejectLink(_url(513), Profiles.HostNotAllowed.selector);
        vm.prank(alice);
        profiles.set("initial", 3, address(0), 0, _url(30));
        assertEq(profiles.profileOf(alice).link, _url(30));
        vm.prank(alice);
        profiles.clear();
        assertEq(profiles.profileOf(alice).link, "");
        _setName(alice, "initial");
        assertEq(profiles.profileOf(alice).link, "");
    }

    function _url(uint256 length) private pure returns (string memory) {
        bytes memory result = new bytes(length);
        bytes memory prefix = "https://arweave.net/";
        for (uint256 i; i < length; ++i) {
            result[i] = i < prefix.length ? prefix[i] : bytes1("a");
        }
        return string(result);
    }

    function _rejectLink(string memory link, bytes4 errorSelector) private {
        bytes memory beforeRecord = abi.encode(profiles.profileOf(alice));
        vm.prank(alice);
        vm.expectRevert(errorSelector);
        profiles.set("replacement", 3, address(0), 0, link);
        assertEq(abi.encode(profiles.profileOf(alice)), beforeRecord);
    }
}
