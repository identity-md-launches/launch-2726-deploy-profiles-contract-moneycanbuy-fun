// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Profiles} from "src/Profiles.sol";
import {TextRules} from "src/helpers/TextRules.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";
import {ProfilesBurnableNFT, ProfilesMultiToken} from "./mocks/ProfilesTestTokens.sol";

/// @dev The oracle uses a finite catalog of known equivalent names, not a copy of the name parser.
///      Expected reservations are derived from the last successful user requests, not from nameOwner.
contract ProfilesHandler is Test {
    Profiles public immutable profiles;
    ProfilesBurnableNFT public immutable nft;
    ProfilesMultiToken public immutable multi;
    MockDelegateRegistry public immutable registry;
    address[4] private actors;
    string[8] private keys = ["qzol", "bravo", "charlle", "delta", "echo", "foxtrot", "golf", "hotel"];
    string[8] private aliases = ["Q_Z_0_I", "BRAV0", "ChArI1E", "DEITA", "ECH0", "F0XTR0T", "G0IF", "H0TE1"];
    Profiles.ProfileView[4] private expected;
    uint256[4] private nameSlots; // 0 = no name, 1..8 = catalog entry
    uint256 private nftHolder;
    uint256[4] private balances;
    bool[4][4] private delegations; // from => to
    uint256 public successfulSets;
    uint256 public rejectedSets;
    string private constant LINK = "https://arweave.net/sequence";
    uint256 private constant ID = type(uint256).max;

    constructor(Profiles p, ProfilesBurnableNFT n, ProfilesMultiToken m, MockDelegateRegistry r) {
        profiles = p;
        nft = n;
        multi = m;
        registry = r;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("sequence actor ", vm.toString(i)));
        }
        nft.mint(actors[0], ID);
        multi.mint(actors[0], ID, 12);
        balances[0] = 12;
    }

    function setProfile(uint256 actorSeed, uint256 nameSeed, uint8 pictureSeed, bool alternate) external {
        uint256 who = actorSeed % actors.length;
        uint256 slot = nameSeed % 9;
        uint8 pic = pictureSeed % 4;
        string memory name = slot == 0 ? "" : alternate ? aliases[slot - 1] : keys[slot - 1];
        address token = pic == 1 ? address(nft) : pic == 2 ? address(multi) : address(0);
        uint256 tokenId = pic == 1 || pic == 2 ? ID : 0;
        string memory link = pic == 3 ? LINK : "";
        bytes4 expectedError;
        if (slot == 0 && pic == 0) expectedError = Profiles.BadName.selector;
        for (uint256 i; i < actors.length; ++i) {
            if (slot != 0 && i != who && nameSlots[i] == slot) expectedError = Profiles.NameTaken.selector;
        }
        if (expectedError == bytes4(0) && (pic == 1 || pic == 2) && !_owned(who, pic)) {
            expectedError = Profiles.NotNftOwner.selector;
        }

        vm.prank(actors[who]);
        (bool ok, bytes memory result) =
            address(profiles).call(abi.encodeCall(Profiles.set, (name, pic, token, tokenId, link)));
        if (expectedError != bytes4(0)) {
            assertFalse(ok, "invalid request unexpectedly succeeded");
            assertEq(result, abi.encodeWithSelector(expectedError), "wrong failure path");
            ++rejectedSets;
            return;
        }
        assertTrue(ok, "valid request failed");
        uint64 since = expected[who].since;
        if (since == 0) since = uint64(block.timestamp);
        expected[who] = Profiles.ProfileView(name, pic, token, tokenId, link, false, since);
        nameSlots[who] = slot;
        ++successfulSets;
    }

    function clearProfile(uint256 actorSeed) public {
        uint256 who = actorSeed % actors.length;
        vm.prank(actors[who]);
        profiles.clear();
        delete expected[who];
        nameSlots[who] = 0;
    }

    function transfer721(uint256 recipientSeed) external {
        uint256 recipient = recipientSeed % actors.length;
        vm.prank(actors[nftHolder]);
        nft.transferFrom(actors[nftHolder], actors[recipient], ID);
        nftHolder = recipient;
    }

    function transfer1155(uint256 fromSeed, uint256 recipientSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % actors.length;
        uint256 to = recipientSeed % actors.length;
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(actors[from]);
        multi.safeTransferFrom(actors[from], actors[to], ID, amount, "");
        balances[from] -= amount;
        balances[to] += amount;
    }

    function delegate721(uint256 fromSeed, uint256 toSeed, bool enabled) external {
        uint256 from = fromSeed % actors.length;
        uint256 to = toSeed % actors.length;
        vm.prank(actors[from]);
        registry.delegateAll(actors[to], enabled);
        delegations[from][to] = enabled;
    }

    function advanceTime(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 1 days));
    }

    function invalidUpdate(uint256 actorSeed, uint8 kindSeed) external {
        uint256 who = actorSeed % actors.length;
        uint8 kind = kindSeed % 5;
        string memory name = kind == 0 ? "_a_" : kind == 1 ? "M_0_D" : "replacement";
        uint8 pic = kind == 2 ? 255 : kind >= 3 ? 3 : 0;
        string memory link = kind == 3 ? "https://evil.example/image" : kind == 4 ? "https://arweave.net/a b" : "";
        bytes4 expectedError = kind == 0
            ? Profiles.BadName.selector
            : kind == 1
                ? Profiles.NameReserved.selector
                : kind == 2
                    ? Profiles.BadPicture.selector
                    : kind == 3 ? Profiles.HostNotAllowed.selector : Profiles.BadEvidence.selector;
        vm.prank(actors[who]);
        (bool ok, bytes memory result) =
            address(profiles).call(abi.encodeCall(Profiles.set, (name, pic, address(0), uint256(0), link)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(expectedError));
        ++rejectedSets;
    }

    function _owned(uint256 who, uint8 pic) private view returns (bool) {
        if (pic == 1) return who == nftHolder || delegations[nftHolder][who];
        if (pic == 2) return balances[who] != 0;
        return pic == 3;
    }

    function assertState() external view {
        address[] memory users = new address[](actors.length + 2);
        for (uint256 i; i < actors.length; ++i) {
            users[i] = actors[i];
        }
        users[actors.length] = actors[0]; // Repeated input must have the same output.
        users[actors.length + 1] = address(0); // Unset input must be empty.
        Profiles.ProfileView[] memory batch = profiles.profilesOf(users);
        assertEq(batch.length, users.length);
        for (uint256 i; i < actors.length; ++i) {
            Profiles.ProfileView memory model = expected[i];
            model.owned = _owned(i, model.pic);
            assertEq(abi.encode(profiles.profileOf(actors[i])), abi.encode(model), "record differs from requests");
            assertEq(abi.encode(batch[i]), abi.encode(model), "batch order/content differs");
            assertEq(multi.balanceOf(actors[i], ID), balances[i], "Profiles changed token holdings");
        }
        assertEq(abi.encode(batch[actors.length]), abi.encode(batch[0]));
        Profiles.ProfileView memory empty;
        assertEq(abi.encode(batch[actors.length + 1]), abi.encode(empty));
        for (uint256 slot = 1; slot <= keys.length; ++slot) {
            address expectedOwner;
            for (uint256 i; i < actors.length; ++i) {
                if (nameSlots[i] == slot) {
                    assertEq(expectedOwner, address(0), "two records cannot share a skeleton");
                    expectedOwner = actors[i];
                }
            }
            assertEq(profiles.nameOwner(bytes20(bytes(keys[slot - 1]))), expectedOwner, "orphaned name reservation");
            assertEq(profiles.ownerOfName(keys[slot - 1]), expectedOwner);
            assertEq(profiles.ownerOfName(aliases[slot - 1]), expectedOwner);
        }
        assertEq(profiles.ownerOfName("replacement"), address(0));
        assertEq(profiles.ownerOfName("mod"), address(0));
        assertEq(nft.ownerOf(ID), actors[nftHolder]);
        assertEq(address(profiles).balance, 0);
        assertEq(multi.balanceOf(address(profiles), ID), 0);
    }
}

/// @dev No balances are managed by Profiles. These invariants exercise its identity state machine instead.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract ProfilesInvariantTest is Test {
    ProfilesHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockDelegateRegistry registry = new MockDelegateRegistry();
        Profiles profiles = new Profiles(address(new TextRules()), address(registry));
        handler = new ProfilesHandler(profiles, new ProfilesBurnableNFT(), new ProfilesMultiToken(), registry);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.setProfile.selector;
        selectors[1] = handler.clearProfile.selector;
        selectors[2] = handler.transfer721.selector;
        selectors[3] = handler.transfer1155.selector;
        selectors[4] = handler.delegate721.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.invalidUpdate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_RecordsReservationsAndLiveOwnershipMatchUserActions() public view {
        handler.assertState();
    }

    function afterInvariant() public {
        // Every random history remains clearable, and every released name can be claimed again.
        for (uint256 i; i < 4; ++i) {
            handler.clearProfile(i);
        }
        handler.assertState();
        for (uint256 i = 1; i <= 8; ++i) {
            handler.setProfile(0, i, 0, true);
            handler.assertState();
        }
    }

    function test_HandlerExercisesSuccessFailureRevocationAndReclaim() public {
        handler.setProfile(0, 1, 1, true);
        handler.assertState();
        handler.transfer721(1);
        handler.assertState();
        handler.setProfile(0, 1, 1, false); // Former owner fails.
        handler.setProfile(1, 1, 1, false); // Current owner still cannot take the name.
        handler.clearProfile(0);
        handler.setProfile(1, 1, 1, false);
        handler.setProfile(1, 0, 3, false); // Picture-only replacement releases the name.
        handler.delegate721(1, 0, true);
        handler.setProfile(0, 1, 1, true);
        handler.delegate721(1, 0, false);
        handler.assertState();
        handler.advanceTime(1 days);
        handler.setProfile(0, 2, 2, false);
        handler.transfer1155(0, 2, 12);
        for (uint8 i; i < 5; ++i) {
            handler.invalidUpdate(0, i);
        }
        handler.assertState();
        assertGt(handler.successfulSets(), 0);
        assertEq(handler.rejectedSets(), 7);
        afterInvariant();
    }
}
