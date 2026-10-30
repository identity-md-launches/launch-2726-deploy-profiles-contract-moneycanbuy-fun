// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Profiles} from "../src/Profiles.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";

/// @dev Test-only responder for adversarial ERC-165, ownership and registry calls.
contract ProfileResponseProbe {
    struct Response {
        uint256 word;
        uint8 mode;
        bytes32 inputHash;
    }

    mapping(bytes4 => Response) private responses;
    uint256 public touched = 1;

    function configure(bytes4 selector, uint256 word, uint8 mode, bytes32 inputHash) external {
        responses[selector] = Response(word, mode, inputHash);
    }

    fallback() external {
        require(gasleft() <= 30_000, "uncapped external call");
        Response memory r = responses[msg.sig];
        require(r.inputHash == bytes32(0) || keccak256(msg.data) == r.inputHash, "wrong call arguments");
        uint256 word = r.word;
        if (r.mode == 1) {
            assembly ("memory-safe") {
                mstore(0, word)
                return(0, 31)
            }
        }
        if (r.mode == 2) {
            assembly ("memory-safe") {
                mstore(0, word)
                revert(0, 32)
            }
        }
        if (r.mode == 3) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (r.mode == 4) {
            assembly {
                return(0, 200000)
            }
        }
        // This affordable write must fail because Profiles uses STATICCALL.
        if (r.mode == 5) touched = 2;
        assembly ("memory-safe") {
            mstore(0, word)
            return(0, 32)
        }
    }
}

contract ProfilesAuditTest is Test {
    bytes4 constant SUPPORTS_INTERFACE = 0x01ffc9a7;
    bytes4 constant OWNER_OF = 0x6352211e;
    bytes4 constant BALANCE_OF = 0x00fdd58e;
    bytes4 constant CHECK_DELEGATE = IDelegateRegistry.checkDelegateForERC721.selector;
    string constant LINK = "https://arweave.net/profile.png";

    Profiles profiles;
    ProfileResponseProbe token;
    ProfileResponseProbe registry;
    address alice;
    address bob;
    address carol;

    function setUp() public {
        alice = makeAddr("profile Alice");
        bob = makeAddr("profile Bob");
        carol = makeAddr("profile Carol");
        token = new ProfileResponseProbe();
        registry = new ProfileResponseProbe();
        profiles = new Profiles(address(new TextRules()), address(registry));
        token.configure(SUPPORTS_INTERFACE, 1, 0, bytes32(0));
        token.configure(OWNER_OF, uint256(uint160(bob)), 0, keccak256(abi.encodeWithSelector(OWNER_OF, uint256(827))));
        token.configure(BALANCE_OF, 1, 0, keccak256(abi.encodeWithSelector(BALANCE_OF, alice, uint256(827))));
        registry.configure(CHECK_DELEGATE, 1, 0, _delegationHash(bob));
    }

    function _delegationHash(address holder) private view returns (bytes32) {
        return
            keccak256(abi.encodeWithSelector(CHECK_DELEGATE, alice, holder, address(token), uint256(827), bytes32(0)));
    }

    function _name(address user, string memory name) private {
        vm.prank(user);
        profiles.set(name, 0, address(0), 0, "");
    }

    function _record(address user) private view returns (bytes memory) {
        return abi.encode(profiles.profileOf(user));
    }

    function test_RegistryFailuresDoNotBreakBatchOrReleaseName() public {
        vm.prank(alice);
        profiles.set("alice", 1, address(token), 827, "");
        vm.prank(bob);
        profiles.set("bob", 1, address(token), 827, "");
        vm.prank(carol);
        profiles.set("carol", 3, address(0), 0, LINK);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        assertTrue(profiles.profileOf(alice).owned);

        for (uint8 mode = 1; mode <= 5; ++mode) {
            registry.configure(CHECK_DELEGATE, 1, mode, _delegationHash(bob));
            uint256 beforeGas = gasleft();
            Profiles.ProfileView[] memory batch = profiles.profilesOf{gas: 500_000}(users);
            assertLt(beforeGas - gasleft(), 200_000);
            assertFalse(batch[0].owned);
            assertEq(batch[0].name, "alice");
            assertTrue(batch[1].owned); // Direct ownership does not need the registry.
            assertTrue(batch[2].owned);
            assertEq(batch[2].link, LINK);
            bytes memory beforeRecord = _record(alice);
            vm.prank(alice);
            vm.expectRevert(Profiles.NotNftOwner.selector);
            profiles.set{gas: 500_000}("replacement", 1, address(token), 827, "");
            assertEq(_record(alice), beforeRecord);
            assertEq(profiles.ownerOfName("alice"), alice);
            assertEq(profiles.ownerOfName("replacement"), address(0));
        }
        assertEq(registry.touched(), 1);
        vm.prank(alice);
        profiles.clear();
        _name(carol, "ALICE");
        assertEq(profiles.ownerOfName("alice"), carol);
    }

    function testFuzz_RegistryOnlyAcceptsCanonicalTrue(uint256 word) public {
        vm.prank(alice);
        profiles.set("alice", 1, address(token), 827, "");
        registry.configure(CHECK_DELEGATE, word, 0, _delegationHash(bob));
        assertEq(profiles.profileOf(alice).owned, word == 1);
        if (word != 1) {
            vm.prank(alice);
            vm.expectRevert(Profiles.NotNftOwner.selector);
            profiles.set("alice", 1, address(token), 827, "");
        }
    }

    function test_DelegationUsesCurrentOwnerAndAllRights() public {
        vm.prank(alice);
        profiles.set("alice", 1, address(token), 827, "");
        assertTrue(profiles.profileOf(alice).owned);
        token.configure(OWNER_OF, uint256(uint160(carol)), 0, bytes32(0));
        // A response configured for the former holder cannot authorize the new holder's token.
        assertFalse(profiles.profileOf(alice).owned);
        registry.configure(CHECK_DELEGATE, 1, 0, _delegationHash(carol));
        assertTrue(profiles.profileOf(alice).owned);
        assertEq(profiles.ownerOfName("alice"), alice);
    }

    function test_TokenCallsAreStaticAndGasCapped() public {
        for (uint8 pic = 1; pic <= 2; ++pic) {
            bytes4 selector = pic == 1 ? OWNER_OF : BALANCE_OF;
            uint256 word = pic == 1 ? uint256(uint160(alice)) : 1;
            token.configure(selector, word, 0, bytes32(0));
            token.configure(
                SUPPORTS_INTERFACE,
                1,
                0,
                keccak256(
                    abi.encodeWithSelector(SUPPORTS_INTERFACE, pic == 1 ? bytes4(0x80ac58cd) : bytes4(0xd9b67a26))
                )
            );
            vm.prank(alice);
            profiles.set("alice", pic, address(token), 827, "");
            assertTrue(profiles.profileOf(alice).owned);
            token.configure(selector, word, 5, bytes32(0));
            assertFalse(profiles.profileOf(alice).owned);
            vm.prank(alice);
            vm.expectRevert(Profiles.NotNftOwner.selector);
            profiles.set("alice", pic, address(token), 827, "");
            token.configure(selector, word, 0, bytes32(0));
        }
        token.configure(SUPPORTS_INTERFACE, 1, 5, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("alice", 1, address(token), 827, "");
        assertEq(token.touched(), 1);
    }

    function test_InterfaceFailuresRejectWithoutChangingRecord() public {
        _name(alice, "alice");
        bytes memory beforeRecord = _record(alice);
        for (uint8 mode = 1; mode <= 5; ++mode) {
            token.configure(SUPPORTS_INTERFACE, 1, mode, bytes32(0));
            vm.prank(alice);
            vm.expectRevert(Profiles.BadPicture.selector);
            profiles.set{gas: 500_000}("replacement", 1, address(token), 827, "");
            assertEq(_record(alice), beforeRecord);
            assertEq(profiles.ownerOfName("replacement"), address(0));
        }
    }

    function test_FailedUpdatesPreserveWholeRecord() public {
        vm.prank(alice);
        profiles.set("alice", 3, address(0), 0, LINK);
        _name(bob, "bob");
        bytes memory beforeRecord = _record(alice);
        vm.startPrank(alice);
        vm.expectRevert(Profiles.NameTaken.selector);
        profiles.set("BOB", 0, address(0), 0, "");
        vm.expectRevert(Profiles.BadName.selector);
        profiles.set("a__", 0, address(0), 0, "");
        vm.expectRevert(Profiles.NameReserved.selector);
        profiles.set("ad_m1n", 0, address(0), 0, "");
        vm.expectRevert(Profiles.HostNotAllowed.selector);
        profiles.set("replacement", 3, address(0), 0, "https://arweave.net.evil.example/a");
        vm.expectRevert(Profiles.BadEvidence.selector);
        profiles.set("replacement", 3, address(0), 0, "https://arweave.net/a b");
        vm.stopPrank();
        assertEq(_record(alice), beforeRecord);
        assertEq(profiles.ownerOfName("alice"), alice);
        assertEq(profiles.ownerOfName("bob"), bob);
        assertEq(profiles.ownerOfName("replacement"), address(0));
    }

    function testFuzz_NameOwnershipSurvivesRenameAndClear(uint256 seed) public {
        // Construct equivalent names from known character pairs, without calling the parser under test.
        bytes memory alphabet = "abcolxyz23456789";
        uint256 length = 3 + seed % 8;
        bytes memory canonical = new bytes(length);
        bytes memory variant = new bytes(length * 2);
        canonical[0] = "q";
        canonical[1] = "z"; // No reserved name or forbidden 0x prefix can result.
        for (uint256 i; i < length; ++i) {
            if (i >= 2) canonical[i] = alphabet[(seed >> (8 * i)) % alphabet.length];
            bytes1 c = canonical[i];
            if (c == "o") c = "0";
            else if (c == "l") c = seed % 2 == 0 ? bytes1("I") : bytes1("1");
            else if (c >= "a" && c <= "z") c = bytes1(uint8(c) - 32);
            variant[2 * i] = c;
            variant[2 * i + 1] = "_";
        }
        bytes20 key = bytes20(canonical);
        vm.warp(1_800_000_000);
        _name(alice, string(canonical));
        vm.prank(bob);
        vm.expectRevert(Profiles.NameTaken.selector);
        profiles.set(string(variant), 0, address(0), 0, "");
        vm.warp(1_800_000_001);
        _name(alice, string(variant));
        assertEq(profiles.nameOwner(key), alice);
        assertEq(profiles.ownerOfName(string(variant)), alice);
        assertEq(profiles.profileOf(alice).name, string(variant));
        assertEq(profiles.profileOf(alice).since, 1_800_000_000);

        string memory replacement = string.concat("zz", string(canonical));
        _name(alice, replacement);
        assertEq(profiles.nameOwner(key), address(0));
        _name(bob, string(variant));
        vm.prank(alice);
        profiles.clear();
        assertEq(profiles.ownerOfName(replacement), address(0));
        assertEq(profiles.nameOwner(key), bob); // Clearing Alice cannot release Bob's newly claimed name.
        vm.prank(bob);
        profiles.clear();
        assertEq(profiles.nameOwner(key), address(0));
        _name(alice, string(canonical));
        assertEq(profiles.profileOf(alice).since, 1_800_000_001);
    }

    function test_EmptyAndDuplicateBatchMatchesIndividualReads() public {
        assertEq(profiles.profilesOf(new address[](0)).length, 0);
        _name(alice, "alice");
        vm.prank(carol);
        profiles.set("", 3, address(0), 0, LINK);
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob; // Unset profile.
        users[2] = alice;
        users[3] = carol;
        Profiles.ProfileView[] memory batch = profiles.profilesOf(users);
        for (uint256 i; i < users.length; ++i) {
            assertEq(abi.encode(batch[i]), _record(users[i]));
        }
    }
}
