// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Profiles} from "../src/Profiles.sol";

/// @dev Local deployment rehearsal only; this contract is not part of the launch.
contract ProfilesFactoryProbe {
    function deploy(bytes32 salt, address textRules, address registry) external returns (Profiles) {
        return new Profiles{salt: salt}(textRules, registry);
    }
}

contract ProfilesLaunchTest is Test {
    address constant TEXT_RULES = 0xAdfe6bd2C17dB514241e1A9B3342F88876073B7F;
    address constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    Profiles profiles;
    ProfilesFactoryProbe factory;

    function setUp() public {
        vm.chainId(1);
        // The launch floor has no code at either dependency when the constructor runs.
        assertEq(TEXT_RULES.code.length, 0);
        assertEq(DELEGATE_REGISTRY.code.length, 0);
        factory = new ProfilesFactoryProbe();
        profiles = factory.deploy(keccak256("Profiles launch rehearsal"), TEXT_RULES, DELEGATE_REGISTRY);
    }

    function test_FactoryDeploymentUsesExactArgumentsWithoutInitialization() public view {
        bytes memory initCode = abi.encodePacked(type(Profiles).creationCode, abi.encode(TEXT_RULES, DELEGATE_REGISTRY));
        bytes32 prediction = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(factory), keccak256("Profiles launch rehearsal"), keccak256(initCode)
            )
        );
        assertEq(address(profiles), address(uint160(uint256(prediction))));
        assertEq(profiles.textRules(), TEXT_RULES);
        assertEq(profiles.delegateRegistry(), DELEGATE_REGISTRY);
        assertEq(profiles.PIC_NONE(), 0);
        assertEq(profiles.PIC_ERC721(), 1);
        assertEq(profiles.PIC_ERC1155(), 2);
        assertEq(profiles.PIC_LINK(), 3);
        assertEq(profiles.CALL_GAS(), 30_000);
        assertGt(address(profiles).code.length, 0);
        assertLe(address(profiles).code.length, 24_576);
        assertLe(initCode.length, 49_152);
        assertEq(address(profiles).balance, 0);
    }

    function test_FirstCallerCanSetAndClearAfterFactoryDeployment() public {
        address user = makeAddr("first profile user");
        vm.startPrank(user);
        profiles.set("first_user", 0, address(0), 0, "");
        assertEq(profiles.ownerOfName("FIRSTUSER"), user);
        assertEq(profiles.profileOf(user).name, "first_user");
        profiles.clear();
        vm.stopPrank();
        assertEq(profiles.ownerOfName("first_user"), address(0));
        assertEq(profiles.profileOf(user).since, 0);
    }
}
