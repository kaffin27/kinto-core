// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/utils/Strings.sol";

import "../src/KintoID.sol";
import "../src/interfaces/IKintoID.sol";

import "./helpers/KYCSignature.sol";
import "./helpers/UUPSProxy.sol";
import {AATestScaffolding} from "./helpers/AATestScaffolding.sol";
import {UserOp} from "./helpers/UserOp.sol";

contract KintoIDv2 is KintoID {
    constructor() KintoID() {}

    function newFunction() public pure returns (uint256) {
        return 1;
    }
}

contract KintoIDTest is KYCSignature, AATestScaffolding, UserOp {
    KintoIDv2 _kintoIDv2;

    function setUp() public {
        vm.chainId(1);
        vm.startPrank(_owner);
        _implementation = new KintoID();

        // deploy _proxy contract and point it to _implementation
        _proxy = new UUPSProxy(address(_implementation), "");

        // wrap in ABI to support easier calls
        _kintoID = KintoID(address(_proxy));

        // Initialize _proxy
        _kintoID.initialize();
        _kintoID.grantRole(_kintoID.KYC_PROVIDER_ROLE(), _kycProvider);
        vm.stopPrank();
    }

    function testUp() public {
        assertEq(_kintoID.lastMonitoredAt(), block.timestamp);
        assertEq(_kintoID.name(), "Kinto ID");
        assertEq(_kintoID.symbol(), "KINTOID");
    }
    /* ============ Upgrade tests ============ */

    function testUpgradeTo() public {
        vm.startPrank(_owner);
        KintoIDv2 _implementationV2 = new KintoIDv2();
        _kintoID.upgradeTo(address(_implementationV2));

        // ensure that the _proxy is now pointing to the new implementation
        _kintoIDv2 = KintoIDv2(address(_proxy));
        assertEq(_kintoIDv2.newFunction(), 1);
        vm.stopPrank();
    }

    function testUpgradeTo_RevertWhen_CallerIsNotOwner() public {
        KintoIDv2 _implementationV2 = new KintoIDv2();

        bytes memory err = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(address(this)),
            " is missing role ",
            Strings.toHexString(uint256(_implementationV2.UPGRADER_ROLE()), 32)
        );
        vm.expectRevert(err);
        _kintoID.upgradeTo(address(_implementationV2));
    }

    function testAuthorizedCanUpgrade() public {
        assertEq(false, _kintoID.hasRole(_kintoID.UPGRADER_ROLE(), _upgrader));

        vm.startPrank(_owner);
        _kintoID.grantRole(_kintoID.UPGRADER_ROLE(), _upgrader);
        vm.stopPrank();

        // upgrade from the _upgrader account
        assertEq(true, _kintoID.hasRole(_kintoID.UPGRADER_ROLE(), _upgrader));

        KintoIDv2 _implementationV2 = new KintoIDv2();
        vm.prank(_upgrader);
        _kintoID.upgradeTo(address(_implementationV2));

        // re-wrap the _proxy
        _kintoIDv2 = KintoIDv2(address(_proxy));
        assertEq(_kintoIDv2.newFunction(), 1);
    }

    /* ============ Mint tests ============ */

    function testMintIndividualKYC() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](0);
        vm.startPrank(_kycProvider);
        assertEq(_kintoID.isKYC(_user), false);
        _kintoID.mintIndividualKyc(sigdata, traits);
        assertEq(_kintoID.isKYC(_user), true);
        assertEq(_kintoID.isIndividual(_user), true);
        assertEq(_kintoID.mintedAt(_user), block.timestamp);
        assertEq(_kintoID.hasTrait(_user, 1), false);
        assertEq(_kintoID.hasTrait(_user, 2), false);
        assertEq(_kintoID.balanceOf(_user), 1);
    }

    function testMintCompanyKYC() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](2);
        traits[0] = 2;
        traits[1] = 5;
        vm.startPrank(_kycProvider);
        _kintoID.mintCompanyKyc(sigdata, traits);
        assertEq(_kintoID.isKYC(_user), true);
        assertEq(_kintoID.isCompany(_user), true);
        assertEq(_kintoID.mintedAt(_user), block.timestamp);
        assertEq(_kintoID.hasTrait(_user, 1), false);
        assertEq(_kintoID.hasTrait(_user, 2), true);
        assertEq(_kintoID.hasTrait(_user, 5), true);
        assertEq(_kintoID.balanceOf(_user), 1);
    }

    function testMintIndividualKYC_RevertWhen_InvalidSender() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;
        vm.startPrank(_user);
        vm.expectRevert("Invalid Provider");
        _kintoID.mintIndividualKyc(sigdata, traits);
    }

    function testMintIndividualKYC_RevertWhen_InvalidSigner() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, 5, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;
        vm.startPrank(_kycProvider);
        vm.expectRevert("Invalid Signer");
        _kintoID.mintIndividualKyc(sigdata, traits);
    }

    function testMintIndividualKYC_RevertWhen_InvalidNonce() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;
        vm.startPrank(_kycProvider);
        _kintoID.mintIndividualKyc(sigdata, traits);
        vm.expectRevert("Invalid Nonce");
        _kintoID.mintIndividualKyc(sigdata, traits);
    }

    function testMintIndividualKYC_RevertWhen_ExpiredSignature() public {
        vm.warp(block.timestamp + 1000);
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp - 1000);

        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;

        vm.prank(_kycProvider);
        vm.expectRevert("Signature has expired");
        _kintoID.mintIndividualKyc(sigdata, traits);
    }

    function testMintIndividualKYC_RevertWhen_AlreadyMinted() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](0);

        vm.prank(_kycProvider);
        _kintoID.mintIndividualKyc(sigdata, traits);

        // try minting again should revert
        sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        vm.expectRevert("Balance before mint must be 0");
        vm.prank(_kycProvider);
        _kintoID.mintIndividualKyc(sigdata, traits);
    }

    /* ============ Burn tests ============ */

    function testBurn_RevertWhen_UsingBurn() public {
        vm.expectRevert("Use burnKYC instead");
        _kintoID.burn(1);
    }

    function testBurn_RevertWhen_BurnIsCalled() public {
        approveKYC(_kycProvider, _user, _userPk);
        uint256 tokenIdx = _kintoID.tokenOfOwnerByIndex(_user, 0);
        vm.prank(_user);
        vm.expectRevert("Use burnKYC instead");
        _kintoID.burn(tokenIdx);
    }

    function testBurnKYC() public {
        approveKYC(_kycProvider, _user, _userPk);

        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        vm.prank(_kycProvider);
        _kintoID.burnKYC(sigdata);
        assertEq(_kintoID.balanceOf(_user), 0);
    }

    function testBurnKYC_WhenCallerIsNotProvider() public {
        approveKYC(_kycProvider, _user, _userPk);

        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        vm.expectRevert("Invalid Provider");
        vm.startPrank(_user);
        _kintoID.burnKYC(sigdata);
    }

    function testBurnKYC_WhenUserIsNotKYCd() public {
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        vm.expectRevert("Nothing to burn");
        vm.prank(_kycProvider);
        _kintoID.burnKYC(sigdata);
    }

    function testBurnKYC_WhenBurningTwice() public {
        approveKYC(_kycProvider, _user, _userPk);

        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        vm.prank(_kycProvider);
        _kintoID.burnKYC(sigdata);

        sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        vm.expectRevert("Nothing to burn");
        vm.prank(_kycProvider);
        _kintoID.burnKYC(sigdata);
    }

    /* ============ Monitor tests ============ */

    function testMonitorNoChanges() public {
        vm.startPrank(_kycProvider);
        _kintoID.monitor(new address[](0), new IKintoID.MonitorUpdateData[][](0));
        assertEq(_kintoID.lastMonitoredAt(), block.timestamp);
    }

    function test_RevertWhen_LenghtMismatch() public {
        vm.expectRevert("Length mismatch");
        vm.prank(_kycProvider);
        _kintoID.monitor(new address[](2), new IKintoID.MonitorUpdateData[][](1));
    }

    function test_RevertWhen_TooManyAccounts() public {
        vm.expectRevert("Too many accounts to monitor at once");
        vm.prank(_kycProvider);
        _kintoID.monitor(new address[](201), new IKintoID.MonitorUpdateData[][](201));
    }

    function test_RevertWhen_CallerIsNotProvider(address someone) public {
        vm.assume(someone != _kycProvider);
        bytes memory err = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(address(this)),
            " is missing role ",
            Strings.toHexString(uint256(_kintoID.KYC_PROVIDER_ROLE()), 32)
        );
        vm.expectRevert(err);
        _kintoID.monitor(new address[](0), new IKintoID.MonitorUpdateData[][](0));
    }

    function testIsSanctionsMonitored() public {
        vm.prank(_kycProvider);
        _kintoID.monitor(new address[](0), new IKintoID.MonitorUpdateData[][](0));
        assertEq(_kintoID.isSanctionsMonitored(1), true);

        vm.warp(block.timestamp + 7 days);

        assertEq(_kintoID.isSanctionsMonitored(8), true);
        assertEq(_kintoID.isSanctionsMonitored(6), false);
    }

    function testMonitor_WhenPassingTraitsAndSactions() public {
        approveKYC(_kycProvider, _user, _userPk);

        // monitor
        address[] memory accounts = new address[](1);
        accounts[0] = _user;

        IKintoID.MonitorUpdateData[][] memory updates = new IKintoID.MonitorUpdateData[][](1);
        updates[0] = new IKintoID.MonitorUpdateData[](4);
        updates[0][0] = IKintoID.MonitorUpdateData(true, true, 5); // add trait 5
        updates[0][1] = IKintoID.MonitorUpdateData(true, false, 1); // remove trait 1
        updates[0][2] = IKintoID.MonitorUpdateData(false, true, 6); // add sanction 6
        updates[0][3] = IKintoID.MonitorUpdateData(false, false, 2); // remove sanction 2

        vm.prank(_kycProvider);
        _kintoID.monitor(accounts, updates);

        assertEq(_kintoID.hasTrait(_user, 5), true);
        assertEq(_kintoID.hasTrait(_user, 1), false);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 5), true);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 1), true);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 6), false);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 2), true);
    }

    /* ============ Trait tests ============ */

    function testAddTrait() public {
        approveKYC(_kycProvider, _user, _userPk);
        vm.prank(_kycProvider);
        _kintoID.addTrait(_user, 1);
        assertEq(_kintoID.lastMonitoredAt(), block.timestamp);
    }

    function testAddTrait_RevertWhen_CallerIsNotProvider() public {
        approveKYC(_kycProvider, _user, _userPk);
        bytes memory err = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(_user),
            " is missing role ",
            Strings.toHexString(uint256(_kintoID.KYC_PROVIDER_ROLE()), 32)
        );
        vm.expectRevert(err);
        vm.prank(_user);
        _kintoID.addTrait(_user, 1);
    }

    function testAddTrait_RevertWhen_UserIsNotKYCd() public {
        assertEq(_kintoID.isKYC(_user), false);
        vm.expectRevert("Account must have a KYC token");
        vm.prank(_kycProvider);
        _kintoID.addTrait(_user, 1);
    }

    function testRemoveTrait() public {
        vm.startPrank(_kycProvider);
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;
        _kintoID.mintIndividualKyc(sigdata, traits);
        _kintoID.addTrait(_user, 1);
        assertEq(_kintoID.hasTrait(_user, 1), true);
        _kintoID.removeTrait(_user, 1);
        assertEq(_kintoID.hasTrait(_user, 1), false);
        assertEq(_kintoID.lastMonitoredAt(), block.timestamp);
    }

    function testRemoveTrait_RevertWhen_CallerIsNotProvider() public {
        approveKYC(_kycProvider, _user, _userPk);

        bytes memory err = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(_user),
            " is missing role ",
            Strings.toHexString(uint256(_kintoID.KYC_PROVIDER_ROLE()), 32)
        );
        vm.expectRevert(err);
        vm.prank(_user);
        _kintoID.removeTrait(_user, 1);
    }

    function testRemoveTrait_RevertWhen_AccountIsNotKYCd() public {
        vm.expectRevert("Account must have a KYC token");
        vm.prank(_kycProvider);
        _kintoID.removeTrait(_user, 1);
    }

    function testTrais() public {
        approveKYC(_kycProvider, _user, _userPk);

        vm.startPrank(_kycProvider);

        _kintoID.addTrait(_user, 0);
        _kintoID.addTrait(_user, 1);
        _kintoID.addTrait(_user, 2);

        vm.stopPrank();

        bool[] memory traits = _kintoID.traits(_user);
        assertEq(traits[0], true);
        assertEq(traits[1], true);
        assertEq(traits[2], true);
        assertEq(traits[3], false);
    }

    /* ============ Sanction tests ============ */

    function testAddSanction() public {
        vm.startPrank(_kycProvider);
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;
        _kintoID.mintIndividualKyc(sigdata, traits);
        _kintoID.addSanction(_user, 1);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 1), false);
        assertEq(_kintoID.isSanctionsSafe(_user), false);
        assertEq(_kintoID.lastMonitoredAt(), block.timestamp);
    }

    function testRemoveSancion() public {
        vm.startPrank(_kycProvider);
        IKintoID.SignatureData memory sigdata = _auxCreateSignature(_kintoID, _user, _userPk, block.timestamp + 1000);
        uint16[] memory traits = new uint16[](1);
        traits[0] = 1;
        _kintoID.mintIndividualKyc(sigdata, traits);
        _kintoID.addSanction(_user, 1);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 1), false);
        _kintoID.removeSanction(_user, 1);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 1), true);
        assertEq(_kintoID.isSanctionsSafe(_user), true);
        assertEq(_kintoID.lastMonitoredAt(), block.timestamp);
    }

    function testAddSanction_RevertWhen_CallerIsNotKYCProvider() public {
        approveKYC(_kycProvider, _user, _userPk, new uint16[](1));

        bytes memory err = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(_user),
            " is missing role ",
            Strings.toHexString(uint256(_kintoID.KYC_PROVIDER_ROLE()), 32)
        );
        vm.expectRevert(err);
        vm.prank(_user);
        _kintoID.addSanction(_user2, 1);
    }

    function testRemoveSanction_RevertWhen_CallerIsNotKYCProvider() public {
        approveKYC(_kycProvider, _user, _userPk);

        vm.prank(_kycProvider);
        _kintoID.addSanction(_user, 1);
        assertEq(_kintoID.isSanctionsSafeIn(_user, 1), false);

        bytes memory err = abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(_user),
            " is missing role ",
            Strings.toHexString(uint256(_kintoID.KYC_PROVIDER_ROLE()), 32)
        );
        vm.expectRevert(err);
        vm.prank(_user);
        _kintoID.removeSanction(_user2, 1);
    }

    function testAddSanction_RevertWhen_AccountIsNotKYCd() public {
        vm.expectRevert("Account must have a KYC token");
        vm.prank(_kycProvider);
        _kintoID.addSanction(_user, 1);
    }

    function testRemoveSanction_RevertWhen_AccountIsNotKYCd() public {
        vm.expectRevert("Account must have a KYC token");
        vm.prank(_kycProvider);
        _kintoID.removeSanction(_user, 1);
    }

    /* ============ Transfer tests ============ */

    function test_RevertWhen_TransfersAreDisabled() public {
        approveKYC(_kycProvider, _user, _userPk);
        uint256 tokenIdx = _kintoID.tokenOfOwnerByIndex(_user, 0);
        vm.prank(_user);
        vm.expectRevert("Only mint or burn transfers are allowed");
        _kintoID.safeTransferFrom(_user, _user2, tokenIdx);
    }

    function testDappSignature() public {
        // vm.startPrank(_kycProvider);
        // bytes memory sig = hex"0fcafa82e64fcfd3c38209e23270274132e88061f1718c7ff45e8c0ddbbe7cdd59b5af57e10a5d8221baa6ae37b57d02acace7e25fc29cb4025f15269e0939aa1b";
        // bool valid = _auxDappSignature(
        //     IKintoID.SignatureData(
        //         0xf1cE2ca79D49B431652F9597947151cf21efB9C3,
        //         0xf1cE2ca79D49B431652F9597947151cf21efB9C3,
        //         0,
        //         1680614821,
        //         sig
        //     )
        // );
        // assertEq(valid, true);
    }

    /* ============ Supports Interface tests ============ */

    function testSupportsInterface() public {
        bytes4 InterfaceERC721Upgradeable = bytes4(keccak256("balanceOf(address)"))
            ^ bytes4(keccak256("ownerOf(uint256)")) ^ bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"))
            ^ bytes4(keccak256("safeTransferFrom(address,address,uint256)"))
            ^ bytes4(keccak256("transferFrom(address,address,uint256)")) ^ bytes4(keccak256("approve(address,uint256)"))
            ^ bytes4(keccak256("setApprovalForAll(address,bool)")) ^ bytes4(keccak256("getApproved(uint256)"))
            ^ bytes4(keccak256("isApprovedForAll(address,address)"));

        assertTrue(_kintoID.supportsInterface(InterfaceERC721Upgradeable));
    }
}
