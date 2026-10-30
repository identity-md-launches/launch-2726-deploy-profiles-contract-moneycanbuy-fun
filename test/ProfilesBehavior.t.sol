// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Profiles} from "src/Profiles.sol";
import {TextRules} from "src/helpers/TextRules.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";
import {ProfilesBurnableNFT, ProfilesMultiToken, ProfilesReturnData} from "./mocks/ProfilesTestTokens.sol";

contract ProfilesBehaviorTest is Test {
    Profiles private profiles;
    ProfilesBurnableNFT private nft;
    ProfilesMultiToken private multi;
    MockDelegateRegistry private registry;
    address private alice;
    address private bob;
    string private constant LINK = "https://arweave.net/picture";
    uint256 private constant ID = type(uint256).max;

    function setUp() public {
        alice = makeAddr("behavior alice");
        bob = makeAddr("behavior bob");
        registry = new MockDelegateRegistry();
        profiles = new Profiles(address(new TextRules()), address(registry));
        nft = new ProfilesBurnableNFT();
        multi = new ProfilesMultiToken();
        nft.mint(alice, ID);
        multi.mint(alice, ID, 2);
        vm.warp(1_800_000_000);
    }

    function _setPicture(uint8 pic) private {
        address token = pic == 1 ? address(nft) : pic == 2 ? address(multi) : address(0);
        vm.prank(alice);
        profiles.set("display", pic, token, pic == 1 || pic == 2 ? ID : 0, pic == 3 ? LINK : "");
    }

    function test_EveryPictureTransitionReplacesTheWholeRecord() public {
        for (uint8 from; from < 4; ++from) {
            for (uint8 to; to < 4; ++to) {
                vm.prank(alice);
                profiles.clear();
                _setPicture(from);
                uint64 since = profiles.profileOf(alice).since;
                vm.warp(block.timestamp + 1);
                _setPicture(to);
                Profiles.ProfileView memory v = profiles.profileOf(alice);
                assertEq(v.name, "display");
                assertEq(v.pic, to);
                assertEq(v.nft, to == 1 ? address(nft) : to == 2 ? address(multi) : address(0));
                assertEq(v.tokenId, to == 1 || to == 2 ? ID : 0);
                assertEq(v.link, to == 3 ? LINK : "");
                assertEq(v.owned, to != 0);
                assertEq(v.since, since);
                assertEq(profiles.ownerOfName("dlsplay"), alice);
                assertEq(nft.ownerOf(ID), alice, "Profiles never takes custody");
                assertEq(multi.balanceOf(alice, ID), 2);
            }
        }
    }

    function test_ClearIsCallerScopedAndIdempotentAcrossAllPictures() public {
        vm.prank(bob);
        profiles.set("bobby", 3, address(0), 0, LINK);
        bytes memory bobsRecord = abi.encode(profiles.profileOf(bob));
        for (uint8 pic; pic < 4; ++pic) {
            _setPicture(pic);
            vm.prank(alice);
            profiles.clear();
            _assertEmpty(alice);
            vm.prank(alice);
            profiles.clear();
            _assertEmpty(alice);
            assertEq(profiles.ownerOfName("display"), address(0));
            assertEq(profiles.ownerOfName("bobby"), bob);
            assertEq(abi.encode(profiles.profileOf(bob)), bobsRecord);
        }
    }

    function _assertEmpty(address user) private view {
        Profiles.ProfileView memory expected;
        assertEq(abi.encode(profiles.profileOf(user)), abi.encode(expected));
    }

    function test_ZeroAndMaximumTokenIdsAreNotSentinelsForNftPictures() public {
        nft.mint(alice, 0);
        multi.mint(alice, 0, 1);
        for (uint8 pic = 1; pic <= 2; ++pic) {
            address token = pic == 1 ? address(nft) : address(multi);
            vm.prank(alice);
            profiles.set("", pic, token, 0, "");
            assertEq(profiles.profileOf(alice).tokenId, 0);
            assertTrue(profiles.profileOf(alice).owned);
            vm.prank(alice);
            profiles.set("", pic, token, ID, "");
            assertEq(profiles.profileOf(alice).tokenId, ID);
            assertTrue(profiles.profileOf(alice).owned);
        }
    }

    function test_BurnRemintAndPartial1155TransfersAreReflectedWithoutSet() public {
        _setPicture(1);
        nft.burn(ID);
        assertFalse(profiles.profileOf(alice).owned);
        assertEq(profiles.ownerOfName("display"), alice);
        nft.mint(bob, ID);
        assertFalse(profiles.profileOf(alice).owned);
        vm.prank(bob);
        registry.delegateERC721(alice, address(nft), ID, true);
        assertTrue(profiles.profileOf(alice).owned);

        _setPicture(2);
        vm.prank(alice);
        multi.safeTransferFrom(alice, bob, ID, 1, "");
        assertTrue(profiles.profileOf(alice).owned, "one remaining unit is sufficient");
        multi.burn(alice, ID, 1);
        assertFalse(profiles.profileOf(alice).owned);
        vm.prank(bob);
        registry.delegateAll(alice, true);
        assertFalse(profiles.profileOf(alice).owned, "ERC1155 does not use delegation");
        multi.mint(alice, ID, 1);
        assertTrue(profiles.profileOf(alice).owned);
        assertEq(profiles.profileOf(alice).since, 1_800_000_000);
    }

    function test_ApprovalsAndOperatorsAreNotOwnership() public {
        vm.startPrank(alice);
        nft.approve(bob, ID);
        nft.setApprovalForAll(bob, true);
        multi.setApprovalForAll(bob, true);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("bobby", 1, address(nft), ID, "");
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("bobby", 2, address(multi), ID, "");
        vm.stopPrank();
        _assertEmpty(bob);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_UndefinedPictureKindsNeverReleaseTheOldName(uint8 input) public {
        uint8 pic = uint8(bound(input, 4, 255));
        _setPicture(3);
        bytes memory previous = abi.encode(profiles.profileOf(alice));
        vm.prank(alice);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("replacement", pic, address(0), 0, "");
        assertEq(abi.encode(profiles.profileOf(alice)), previous);
        assertEq(profiles.ownerOfName("display"), alice);
        assertEq(profiles.ownerOfName("replacement"), address(0));
    }

    function test_InvalidPictureFieldsPreserveRecordAndReservations() public {
        _setPicture(3);
        bytes memory previous = abi.encode(profiles.profileOf(alice));
        vm.startPrank(alice);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("replacement", 3, address(0), 1, LINK);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("replacement", 2, address(multi), ID, LINK);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("replacement", 1, address(0), 0, "");
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("replacement", 2, bob, ID, "");
        vm.expectRevert(Profiles.BadName.selector);
        profiles.set("", 0, address(0), 0, "");
        vm.stopPrank();
        assertEq(abi.encode(profiles.profileOf(alice)), previous);
        assertEq(profiles.ownerOfName("display"), alice);
        assertEq(profiles.ownerOfName("replacement"), address(0));
    }

    function test_EventWireFormatForEveryPictureAndRepeatedClear() public {
        for (uint8 pic; pic < 4; ++pic) {
            vm.recordLogs();
            _setPicture(pic);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].emitter, address(profiles));
            assertEq(logs[0].topics.length, 2);
            assertEq(logs[0].topics[0], keccak256("ProfileSet(address,string,uint8,address,uint256,string)"));
            assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
            assertEq(
                logs[0].data,
                abi.encode(
                    "display",
                    pic,
                    pic == 1 ? address(nft) : pic == 2 ? address(multi) : address(0),
                    pic == 1 || pic == 2 ? ID : 0,
                    pic == 3 ? LINK : ""
                )
            );
        }
        for (uint256 i; i < 2; ++i) {
            vm.recordLogs();
            vm.prank(alice);
            profiles.clear();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].emitter, address(profiles));
            assertEq(logs[0].topics.length, 2);
            assertEq(logs[0].topics[0], keccak256("ProfileCleared(address)"));
            assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
            assertEq(logs[0].data.length, 0);
        }
    }

    function test_ProfileTupleWireOrderForEveryPicture() public {
        for (uint8 pic; pic < 4; ++pic) {
            _setPicture(pic);
            (bool ok, bytes memory data) =
                address(profiles).staticcall(abi.encodeWithSignature("profileOf(address)", alice));
            assertTrue(ok);
            // A dynamic tuple is preceded by its offset, followed by the specified seven fields.
            bytes memory tuple = abi.encode(
                "display",
                pic,
                pic == 1 ? address(nft) : pic == 2 ? address(multi) : address(0),
                pic == 1 || pic == 2 ? ID : 0,
                pic == 3 ? LINK : "",
                pic != 0,
                uint64(1_800_000_000)
            );
            assertEq(data, bytes.concat(bytes32(uint256(32)), tuple));
        }
    }

    function test_NoFallbackAndNoValueThroughAnyPublicSelector() public {
        _setPicture(3);
        bytes memory previous = abi.encode(profiles.profileOf(alice));
        bytes[] memory calls = new bytes[](16);
        calls[0] = "";
        calls[1] = abi.encodeWithSignature("unknownProfileOperation()");
        calls[2] = abi.encodeCall(Profiles.set, ("replacement", uint8(0), address(0), uint256(0), ""));
        calls[3] = abi.encodeCall(Profiles.clear, ());
        calls[4] = abi.encodeCall(Profiles.profileOf, (alice));
        calls[5] = abi.encodeCall(Profiles.profilesOf, (new address[](0)));
        calls[6] = abi.encodeCall(Profiles.ownerOfName, ("display"));
        calls[7] = abi.encodeWithSignature("nameOwner(bytes20)", bytes20("dlsplay"));
        calls[8] = abi.encodeWithSignature("textRules()");
        calls[9] = abi.encodeWithSignature("delegateRegistry()");
        calls[10] = abi.encodeWithSignature("PIC_NONE()");
        calls[11] = abi.encodeWithSignature("CALL_GAS()");
        calls[12] = abi.encodeWithSignature("owner()");
        calls[13] = abi.encodeWithSignature("PIC_ERC721()");
        calls[14] = abi.encodeWithSignature("PIC_ERC1155()");
        calls[15] = abi.encodeWithSignature("PIC_LINK()");
        vm.deal(alice, 1 ether);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool acceptedValue,) = address(profiles).call{value: 1}(calls[i]);
            assertFalse(acceptedValue);
        }
        (bool ok,) = address(profiles).call("");
        assertFalse(ok);
        (ok,) = address(profiles).call(calls[1]);
        assertFalse(ok);
        (ok,) = address(profiles).call(calls[12]);
        assertFalse(ok);
        assertEq(abi.encode(profiles.profileOf(alice)), previous);
        assertEq(address(profiles).balance, 0);
    }

    function test_RequiredErrorSelectorsRemainStable() public pure {
        assertEq(Profiles.BadName.selector, bytes4(keccak256("BadName()")));
        assertEq(Profiles.NameTaken.selector, bytes4(keccak256("NameTaken()")));
        assertEq(Profiles.NameReserved.selector, bytes4(keccak256("NameReserved()")));
        assertEq(Profiles.BadPicture.selector, bytes4(keccak256("BadPicture()")));
        assertEq(Profiles.NotNftOwner.selector, bytes4(keccak256("NotNftOwner()")));
        assertEq(Profiles.ZeroAddress.selector, bytes4(keccak256("ZeroAddress()")));
        assertEq(Profiles.HostNotAllowed.selector, bytes4(keccak256("HostNotAllowed()")));
        assertEq(Profiles.BadEvidence.selector, bytes4(keccak256("BadEvidence()")));
    }
}

contract ProfilesReturnDataTest is Test {
    bytes4 private constant SUPPORTS = 0x01ffc9a7;
    bytes4 private constant OWNER = 0x6352211e;
    bytes4 private constant BALANCE = 0x00fdd58e;
    bytes4 private constant DELEGATE =
        bytes4(keccak256("checkDelegateForERC721(address,address,address,uint256,bytes32)"));
    Profiles private profiles;
    ProfilesReturnData private token;
    ProfilesReturnData private registry;
    address private alice;
    address private bob;

    function setUp() public {
        alice = makeAddr("response alice");
        bob = makeAddr("response bob");
        token = new ProfilesReturnData();
        registry = new ProfilesReturnData();
        profiles = new Profiles(address(new TextRules()), address(registry));
        token.configure(SUPPORTS, 1, 32, false);
        token.configure(OWNER, uint160(alice), 32, false);
        token.configure(BALANCE, 1, 32, false);
        registry.configure(DELEGATE, 1, 32, false);
    }

    function _set(uint8 pic) private {
        vm.prank(alice);
        profiles.set("response_user", pic, address(token), 0, "");
    }

    function test_AllShortReturnLengthsFailAtEveryExternalBoundary() public {
        for (uint16 length; length < 32; ++length) {
            token.configure(SUPPORTS, 1, length, false);
            vm.prank(alice);
            vm.expectRevert(Profiles.BadPicture.selector);
            profiles.set("response_user", 1, address(token), 0, "");
            token.configure(SUPPORTS, 1, 32, false);
            for (uint8 pic = 1; pic <= 2; ++pic) {
                bytes4 selector = pic == 1 ? OWNER : BALANCE;
                uint256 word = pic == 1 ? uint160(alice) : 1;
                token.configure(selector, word, 32, false);
                _set(pic);
                token.configure(selector, word, length, false);
                assertFalse(profiles.profileOf(alice).owned);
                vm.prank(alice);
                vm.expectRevert(Profiles.NotNftOwner.selector);
                profiles.set("response_user", pic, address(token), 0, "");
                token.configure(selector, word, 32, false);
            }
            token.configure(OWNER, uint160(bob), 32, false);
            registry.configure(DELEGATE, 1, 32, false);
            _set(1);
            registry.configure(DELEGATE, 1, length, false);
            assertFalse(profiles.profileOf(alice).owned);
            vm.prank(alice);
            vm.expectRevert(Profiles.NotNftOwner.selector);
            profiles.set("response_user", 1, address(token), 0, "");
        }
    }

    function test_FailedCallWithAnOtherwiseValidWordIsNotAccepted() public {
        for (uint8 pic = 1; pic <= 2; ++pic) {
            bytes4 selector = pic == 1 ? OWNER : BALANCE;
            uint256 word = pic == 1 ? uint160(alice) : 1;
            _set(pic);
            token.configure(selector, word, 32, true);
            assertFalse(profiles.profileOf(alice).owned);
            token.configure(selector, word, 32, false);
        }
        token.configure(OWNER, uint160(bob), 32, false);
        _set(1);
        registry.configure(DELEGATE, 1, 32, true);
        assertFalse(profiles.profileOf(alice).owned);
        token.configure(SUPPORTS, 1, 32, true);
        vm.prank(alice);
        vm.expectRevert(Profiles.BadPicture.selector);
        profiles.set("response_user", 1, address(token), 0, "");
    }

    function test_CompleteWordWithTrailingDataUsesOnlyTheFirstWord() public {
        // These payloads fit the callee's gas budget. Unlike the 200,000-byte gas bombs in
        // ProfilesAudit.t.sol, a successful response still supplies a valid first word.
        uint16[5] memory lengths = [uint16(32), 33, 64, 4096, 32768];
        for (uint256 i; i < lengths.length; ++i) {
            token.configure(SUPPORTS, 1, lengths[i], false);
            token.configure(OWNER, uint160(bob), lengths[i], false);
            token.configure(BALANCE, type(uint256).max, lengths[i], false);
            registry.configure(DELEGATE, 1, lengths[i], false);
            for (uint8 pic = 1; pic <= 2; ++pic) {
                _set(pic);
                uint256 beforeGas = gasleft();
                Profiles.ProfileView memory value = profiles.profileOf{gas: 300_000}(alice);
                assertLt(beforeGas - gasleft(), 150_000);
                assertTrue(value.owned);
                assertEq(value.name, "response_user");
                assertEq(value.nft, address(token));
            }
        }
    }

    function test_ZeroOrDirtyOwnerCannotBeRescuedByRegistry() public {
        _set(1);
        token.configure(OWNER, 0, 32, false);
        assertFalse(profiles.profileOf(alice).owned);
        vm.prank(alice);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        profiles.set("response_user", 1, address(token), 0, "");
        token.configure(OWNER, uint256(uint160(alice)) | (uint256(1) << 160), 32, false);
        assertFalse(profiles.profileOf(alice).owned);
        token.configure(OWNER, type(uint256).max, 32, false);
        assertFalse(profiles.profileOf(alice).owned);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InterfaceBooleanMustBeCanonical(uint256 input) public {
        token.configure(SUPPORTS, input, 32, false);
        if (input == 1) {
            _set(1);
            assertTrue(profiles.profileOf(alice).owned);
        } else {
            vm.prank(alice);
            vm.expectRevert(Profiles.BadPicture.selector);
            profiles.set("response_user", 1, address(token), 0, "");
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_1155AcceptsAnyPositiveBalance(uint256 amount) public {
        _set(2);
        token.configure(BALANCE, amount, 32, false);
        assertEq(profiles.profileOf(alice).owned, amount != 0);
        if (amount == 0) {
            vm.prank(alice);
            vm.expectRevert(Profiles.NotNftOwner.selector);
            profiles.set("response_user", 2, address(token), 0, "");
        } else {
            _set(2);
            assertTrue(profiles.profileOf(alice).owned);
        }
    }

    function test_NoRegistryCodeFailsClosedButDirectOwnerStillWorks() public {
        Profiles noRegistry = new Profiles(address(new TextRules()), bob);
        vm.prank(alice);
        noRegistry.set("response_user", 1, address(token), 0, "");
        assertTrue(noRegistry.profileOf(alice).owned);
        token.configure(OWNER, uint160(bob), 32, false);
        assertFalse(noRegistry.profileOf(alice).owned);
        vm.prank(alice);
        vm.expectRevert(Profiles.NotNftOwner.selector);
        noRegistry.set("response_user", 1, address(token), 0, "");
    }

    function test_LosingTokenCodeDoesNotBreakBatchAndClear() public {
        _set(1);
        vm.prank(bob);
        profiles.set("bobby", 0, address(0), 0, "");
        vm.etch(address(token), "");
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        Profiles.ProfileView[] memory values = profiles.profilesOf(users);
        assertFalse(values[0].owned);
        assertEq(values[0].name, "response_user");
        assertEq(values[1].name, "bobby");
        vm.prank(alice);
        profiles.clear();
        assertEq(profiles.ownerOfName("response_user"), address(0));
    }
}
