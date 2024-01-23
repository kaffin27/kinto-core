// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@aa/interfaces/IEntryPoint.sol";
import "@aa/core/EntryPoint.sol";

import "../src/apps/KintoAppRegistry.sol";
import "../src/paymasters/SponsorPaymaster.sol";
import "../src/sample/Counter.sol";
import "../src/interfaces/IKintoWallet.sol";

import "./helpers/KYCSignature.sol";
import "./helpers/UUPSProxy.sol";
import "./helpers/UserOp.sol";
import {AATestScaffolding} from "./helpers/AATestScaffolding.sol";

contract SponsorPaymasterUpgrade is SponsorPaymaster {
    constructor(IEntryPoint __entryPoint, address _owner) SponsorPaymaster(__entryPoint) {
        _disableInitializers();
        _transferOwnership(_owner);
    }

    function newFunction() public pure returns (uint256) {
        return 1;
    }
}

contract SponsorPaymasterTest is KYCSignature, UserOp, AATestScaffolding {
    using ECDSAUpgradeable for bytes32;
    using SignatureChecker for address;

    uint256[] privateKeys;

    function setUp() public {
        vm.chainId(1);
        deployAAScaffolding(_owner, 1, _kycProvider, _recoverer);

        // Add paymaster to _kintoWallet
        fundSponsorForApp(address(_kintoWallet));

        // Default tests to use 1 private key for simplicity
        privateKeys = new uint256[](1);

        // Default tests to use _ownerPk unless otherwise specified
        privateKeys[0] = _ownerPk;

        vm.deal(_user, 1e20);
    }

    function testUp() public {
        assertEq(_paymaster.COST_OF_POST(), 200_000);
    }

    /* ============ Upgrade ============ */

    function testOwnerCanUpgrade() public {
        SponsorPaymasterUpgrade _newImplementation = new SponsorPaymasterUpgrade(_entryPoint, _owner);

        vm.prank(_owner);
        _paymaster.upgradeTo(address(_newImplementation));

        // re-wrap the _proxy
        _newImplementation = SponsorPaymasterUpgrade(address(_proxyPaymaster));
        assertEq(_newImplementation.newFunction(), 1);
    }

    function testUpgrade_RevertWhen_CallerIsNotOwner() public {
        SponsorPaymasterUpgrade _newImplementation = new SponsorPaymasterUpgrade(_entryPoint, _owner);
        vm.expectRevert("SP: not owner");
        _paymaster.upgradeTo(address(_newImplementation));
    }

    /* ============ Deposit & Stake ============ */

    function testOwnerCanDepositStakeAndWithdraw() public {
        vm.startPrank(_owner);
        uint256 balance = address(_owner).balance;
        _paymaster.addDepositFor{value: 5e18}(address(_owner));
        assertEq(address(_owner).balance, balance - 5e18);
        _paymaster.unlockTokenDeposit();
        vm.roll(block.number + 1);
        _paymaster.withdrawTokensTo(address(_owner), 5e18);
        assertEq(address(_owner).balance, balance);
        vm.stopPrank();
    }

    function testUserCanDepositStakeAndWithdraw() public {
        vm.startPrank(_user);
        uint256 balance = address(_user).balance;
        _paymaster.addDepositFor{value: 5e18}(address(_user));
        assertEq(address(_user).balance, balance - 5e18);
        _paymaster.unlockTokenDeposit();
        // advance block to allow withdraw
        vm.roll(block.number + 1);
        _paymaster.withdrawTokensTo(address(_user), 5e18);
        assertEq(address(_user).balance, balance);
        vm.stopPrank();
    }

    function test_RevertWhen_UserCanDepositStakeAndWithdrawWithoutRoll() public {
        // user deposits 5 eth
        uint256 balance = address(this).balance;
        _paymaster.addDepositFor{value: 5e18}(address(this));
        assertEq(address(this).balance, balance - 5e18);

        // user unlocks token deposit
        _paymaster.unlockTokenDeposit();

        // user withdraws 5 eth
        vm.expectRevert("SP: must unlockTokenDeposit");
        _paymaster.withdrawTokensTo(address(this), 5e18);

        assertEq(address(this).balance, balance - 5e18);
    }

    function testOwnerCanWithdrawAllInEmergency() public {
        uint256 deposited = _paymaster.getDeposit();

        vm.prank(_user);
        _paymaster.addDepositFor{value: 5e18}(address(_user));

        vm.prank(_owner);
        _paymaster.addDepositFor{value: 5e18}(address(_owner));

        assertEq(_paymaster.getDeposit(), deposited + 10e18);

        deposited = _paymaster.getDeposit();

        uint256 balBefore = address(_owner).balance;
        vm.prank(_owner);
        _paymaster.withdrawTo(payable(_owner), address(_entryPoint).balance);

        assertEq(address(_paymaster).balance, 0);
        assertEq(address(_owner).balance, balBefore + deposited);
    }

    function test_RevertWhen_UserCanWithdrawAllInEmergency() public {
        vm.prank(_owner);
        _paymaster.addDepositFor{value: 5e18}(address(_owner));

        // user deposits 5 eth and then tries to withdraw all
        vm.startPrank(_user);
        _paymaster.addDepositFor{value: 5e18}(address(_user));
        vm.expectRevert("Ownable: caller is not the owner");
        _paymaster.withdrawTo(payable(_user), address(_entryPoint).balance);
        vm.stopPrank();
    }

    /* ============ PER-OP: Global Rate limits ============ */

    function testValidatePaymasterUserOp() public {
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet),
            address(_kintoWallet),
            _kintoWallet.getNonce(),
            privateKeys,
            abi.encodeWithSignature("increment()"),
            address(_paymaster)
        );

        vm.prank(address(_entryPoint));
        _paymaster.validatePaymasterUserOp(userOp, "", 0);
    }

    function testValidatePaymasterUserOp_RevertWhen_GasLimitIsLessThanCostOfPost() public {
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet),
            address(_kintoWallet),
            _kintoWallet.getNonce(),
            privateKeys,
            abi.encodeWithSignature("increment()"),
            address(_paymaster)
        );

        // verificationGasLimit is 1 less than COST_OF_POST
        userOp.verificationGasLimit = _paymaster.COST_OF_POST() - 1;

        vm.prank(address(_entryPoint));
        vm.expectRevert("SP: gas outside of range for postOp");
        _paymaster.validatePaymasterUserOp(userOp, "", 0);
    }

    function testValidatePaymasterUserOp_RevertWhen_GasLimitIsMoreThanCostOfVerification() public {
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet),
            address(_kintoWallet),
            _kintoWallet.getNonce(),
            privateKeys,
            abi.encodeWithSignature("increment()"),
            address(_paymaster)
        );

        // verificationGasLimit is 1 more than COST_OF_POST
        userOp.verificationGasLimit = _paymaster.MAX_COST_OF_VERIFICATION() + 1;

        vm.prank(address(_entryPoint));
        vm.expectRevert("SP: gas outside of range for postOp");
        _paymaster.validatePaymasterUserOp(userOp, "", 0);
    }

    function testValidatePaymasterUserOp_RevertWhen_PreGasLimitIsMoreThanMaxPreVerification() public {
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet),
            address(_kintoWallet),
            _kintoWallet.getNonce(),
            privateKeys,
            abi.encodeWithSignature("increment()"),
            address(_paymaster)
        );

        // preVerificationGas is 1 more than MAX_COST_OF_PREVERIFICATION
        userOp.preVerificationGas = _paymaster.MAX_COST_OF_PREVERIFICATION() + 1;

        vm.prank(address(_entryPoint));
        vm.expectRevert("SP: gas too high for verification");
        _paymaster.validatePaymasterUserOp(userOp, "", 0);
    }

    function testValidatePaymasterUserOp_RevertWhen_PaymasterAndDataIsNotLength20() public {
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet),
            address(_kintoWallet),
            _kintoWallet.getNonce(),
            privateKeys,
            abi.encodeWithSignature("increment()"),
            address(_paymaster)
        );

        // paymasterAndData is 21 bytes
        userOp.paymasterAndData = new bytes(21);

        vm.prank(address(_entryPoint));
        vm.expectRevert("SP: paymasterAndData must contain only paymaster");
        _paymaster.validatePaymasterUserOp(userOp, "", 0);
    }

    function testValidatePaymasterUserOp_RevertWhen_GasIsTooHigh() public {
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet),
            address(_kintoWallet),
            _kintoWallet.getNonce(),
            privateKeys,
            abi.encodeWithSignature("increment()"),
            address(_paymaster)
        );

        // gas price set to 100 ether
        userOp.maxFeePerGas = 100 ether;
        userOp.maxPriorityFeePerGas = 100 ether;

        vm.prank(address(_entryPoint));
        vm.expectRevert("SP: gas too high for user op");
        _paymaster.validatePaymasterUserOp(userOp, "", 0);
    }

    /* ============ Global Rate limits (tx & batched ops rates) ============ */

    function testValidatePaymasterUserOp_WithinTxRateLimit() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;

        // create app with app limits higher than the global ones so we assert that the global is the one that is used in the test
        uint256[4] memory appLimits = [
            _paymaster.RATE_LIMIT_PERIOD() + 1,
            _paymaster.RATE_LIMIT_THRESHOLD_TOTAL() + 1,
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            _kintoAppRegistry.GAS_LIMIT_THRESHOLD()
        ];
        address app = _createApp(appLimits);

        // execute transactions (with one user op per tx) one by one until reaching the threshold
        _incrementCounterTxs(_paymaster.RATE_LIMIT_THRESHOLD_TOTAL(), app);

        // reset period
        vm.warp(block.timestamp + _paymaster.RATE_LIMIT_PERIOD() + 1);

        // can again execute as many transactions as the threshold allows
        _incrementCounterTxs(_paymaster.RATE_LIMIT_THRESHOLD_TOTAL(), app);
    }

    function testValidatePaymasterUserOp_RevertWhen_TxRateLimitExceeded() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;

        // create app with app limits higher than the global ones so we assert that the global is the one that is used in the test
        uint256[4] memory appLimits = [
            _paymaster.RATE_LIMIT_PERIOD() + 1,
            _paymaster.RATE_LIMIT_THRESHOLD_TOTAL() + 1,
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            _kintoAppRegistry.GAS_LIMIT_THRESHOLD()
        ];
        address app = _createApp(appLimits);

        // execute transactions (with one user op per tx) one by one until reaching the threshold
        _incrementCounterTxs(_paymaster.RATE_LIMIT_THRESHOLD_TOTAL(), app);

        // execute one more op and assert that it reverts
        UserOperation[] memory userOps = _incrementCounterOps(1, app);
        vm.expectEmit(true, true, true, false);
        uint256 last = userOps.length - 1;
        emit PostOpRevertReason(
            _entryPoint.getUserOpHash(userOps[last]), userOps[last].sender, userOps[last].nonce, bytes("")
        );
        vm.recordLogs();
        _entryPoint.handleOps(userOps, payable(_owner));
        assertRevertReasonEq("SP: Kinto Rate limit exceeded");
    }

    function testValidatePaymasterUserOp_WithinOpsRateLimit() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;

        // create app with app limits higher than the global ones so we assert that the global is the one that is used in the test
        uint256[4] memory appLimits = [
            _paymaster.RATE_LIMIT_PERIOD() + 1,
            _paymaster.RATE_LIMIT_THRESHOLD_TOTAL() + 1,
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            _kintoAppRegistry.GAS_LIMIT_THRESHOLD()
        ];
        address app = _createApp(appLimits);

        // generate ops until reaching the threshold
        UserOperation[] memory userOps = _incrementCounterOps(_paymaster.RATE_LIMIT_THRESHOLD_TOTAL(), app);
        _entryPoint.handleOps(userOps, payable(_owner));
    }

    function testValidatePaymasterUserOp_RevertWhen_OpsRateLimitExceeded() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;

        // create app with app limits higher than the global ones so we assert that the global is the one that is used in the test
        uint256[4] memory appLimits = [
            _paymaster.RATE_LIMIT_PERIOD() + 1,
            _paymaster.RATE_LIMIT_THRESHOLD_TOTAL() + 1,
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            _kintoAppRegistry.GAS_LIMIT_THRESHOLD()
        ];
        address app = _createApp(appLimits);

        // generate ops until reaching the threshold and assert that it reverts
        UserOperation[] memory userOps = _incrementCounterOps(_paymaster.RATE_LIMIT_THRESHOLD_TOTAL() + 1, app);
        vm.expectEmit(true, true, true, false);
        uint256 last = userOps.length - 1;
        emit PostOpRevertReason(
            _entryPoint.getUserOpHash(userOps[last]), userOps[last].sender, userOps[last].nonce, bytes("")
        );
        vm.recordLogs();
        _entryPoint.handleOps(userOps, payable(_owner));
        assertRevertReasonEq("SP: Kinto Rate limit exceeded");
    }

    /* ============ App Rate limits (tx & batched ops rates) ============ */

    function testValidatePaymasterUserOp_WithinAppTxRateLimit() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;
        address app = _createApp();
        uint256[4] memory appLimits = _kintoAppRegistry.getContractLimits(app);

        // execute transactions (with one user op per tx) one by one until reaching the threshold
        _incrementCounterTxs(appLimits[1], app);
    }

    function testValidatePaymasterUserOp_RevertWhen_AppTxRateLimitExceeded() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;
        address app = _createApp();
        uint256[4] memory appLimits = _kintoAppRegistry.getContractLimits(app);

        // execute transactions (with one user op per tx) one by one until reaching the threshold
        _incrementCounterTxs(appLimits[1], app);

        // execute one more op and assert that it reverts
        UserOperation[] memory userOps = _incrementCounterOps(1, app);
        vm.expectEmit(true, true, true, false);
        uint256 last = userOps.length - 1;
        emit PostOpRevertReason(
            _entryPoint.getUserOpHash(userOps[last]), userOps[last].sender, userOps[last].nonce, bytes("")
        );
        vm.recordLogs();
        _entryPoint.handleOps(userOps, payable(_owner));
        assertRevertReasonEq("SP: App Rate limit exceeded");
    }

    function testValidatePaymasterUserOp_WithinAppOpsRateLimit() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;
        address app = _createApp();
        uint256[4] memory appLimits = _kintoAppRegistry.getContractLimits(app);

        // generate ops until reaching the threshold
        UserOperation[] memory userOps = _incrementCounterOps(appLimits[1], app);
        _entryPoint.handleOps(userOps, payable(_owner));
    }

    function testValidatePaymasterUserOp_RevertWhen_AppOpsRateLimitExceeded() public {
        // fixme: once _setOperationCount works fine, refactor and use _setOperationCount;
        address app = _createApp();
        uint256[4] memory appLimits = _kintoAppRegistry.getContractLimits(app);

        // generate ops until reaching the threshold and assert that it reverts
        UserOperation[] memory userOps = _incrementCounterOps(appLimits[1] + 1, app);
        vm.expectEmit(true, true, true, false);
        uint256 last = userOps.length - 1;
        emit PostOpRevertReason(
            _entryPoint.getUserOpHash(userOps[last]), userOps[last].sender, userOps[last].nonce, bytes("")
        );
        vm.recordLogs();
        _entryPoint.handleOps(userOps, payable(_owner));
        assertRevertReasonEq("SP: App Rate limit exceeded");
    }

    /* ============ App Gas limits  (tx & batched ops rates) ============ */

    function testValidatePaymasterUserOp_RevertWhen_AppTxGasLimitLimitExceeded() public {
        /// fixme: once _setOperationCount works fine, refactor and use _setOperationCount;
        /// @dev create app with high app limits and low gas limit so we assert that the one used
        // in the test is the gas limit
        uint256[4] memory appLimits = [
            100e18,
            100e18,
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            0.000000000001 ether //
        ];
        address app = _createApp(appLimits);

        // execute transactions (with one user op per tx) one by one until reaching the gas limit
        _incrementCounterTxsUntilGasLimit(app);

        // execute one more op and assert that it reverts
        UserOperation[] memory userOps = _incrementCounterOps(1, app);
        vm.expectEmit(true, true, true, false);
        emit PostOpRevertReason(_entryPoint.getUserOpHash(userOps[0]), userOps[0].sender, userOps[0].nonce, bytes(""));
        vm.recordLogs();
        _entryPoint.handleOps(userOps, payable(_owner));
        assertRevertReasonEq("SP: Kinto Gas App limit exceeded");
    }

    function testValidatePaymasterUserOp_RevertWhen_AppOpsGasLimitLimitExceeded() public {
        /// fixme: once _setOperationCount works fine, refactor and use _setOperationCount;
        /// @dev create app with high app limits and low gas limit so we assert that the one used
        // in the test is the gas limit
        uint256[4] memory appLimits = [
            100e18,
            100e18,
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            0.000000000001 ether //
        ];
        address app = _createApp(appLimits);

        // execute transactions until reaching gas limit and save the amount of apps that reached the threshold
        uint256 amt = _incrementCounterTxsUntilGasLimit(app);

        // reset period
        // fixme: vm.warp(block.timestamp + _kintoAppRegistry.GAS_LIMIT_PERIOD() + 1);

        // generate `amt` ops until reaching the threshold and assert that it reverts
        UserOperation[] memory userOps = _incrementCounterOps(amt, app);
        vm.expectEmit(true, true, true, false);
        uint256 last = userOps.length - 1;
        emit PostOpRevertReason(
            _entryPoint.getUserOpHash(userOps[last]), userOps[last].sender, userOps[last].nonce, bytes("")
        );
        vm.recordLogs();
        _entryPoint.handleOps(userOps, payable(_owner));
        assertRevertReasonEq("SP: Kinto Gas App limit exceeded");
    }

    function testValidatePaymasterUserOp_RevertWhen_WhenNotRelated_WhenBatch() public {
        // if intermediate calls are neither sponsored contracts nor children of an app, it should NOT validate the signature

        // deploy a counter contract
        Counter counter = new Counter();
        assertEq(counter.count(), 0);

        // deploy a second counter contract
        Counter unknown = new Counter();
        assertEq(unknown.count(), 0);

        // prep batch
        address[] memory targets = new address[](3);
        targets[0] = address(_kintoWallet);
        targets[1] = address(unknown);
        targets[2] = address(counter);

        uint256[] memory values = new uint256[](3);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;

        // we want to do 3 calls: whitelistApp, increment counter and increment counter2
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("isFunderWhitelisted()");
        calls[1] = abi.encodeWithSignature("increment()");
        calls[2] = abi.encodeWithSignature("increment()");

        // send all transactions via batch
        OperationParamsBatch memory opParams = OperationParamsBatch({targets: targets, values: values, bytesOps: calls});
        UserOperation memory userOp = _createUserOperation(
            address(_kintoWallet), _kintoWallet.getNonce(), privateKeys, opParams, address(_paymaster)
        );
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;

        // execute the transaction via the entry point

        // prepare expected error message
        uint256 expectedOpIndex = 0; // Adjust as needed
        string memory expectedMessage = "AA33 reverted";
        bytes memory additionalMessage =
            abi.encodePacked("SP: executeBatch targets must be sponsored by the contract or be the sender wallet");
        bytes memory expectedAdditionalData = abi.encodeWithSelector(
            bytes4(keccak256("Error(string)")), // Standard error selector
            additionalMessage
        );

        // encode the entire revert reason
        bytes memory expectedRevertReason = abi.encodeWithSignature(
            "FailedOpWithRevert(uint256,string,bytes)", expectedOpIndex, expectedMessage, expectedAdditionalData
        );

        vm.expectRevert(expectedRevertReason);
        _entryPoint.handleOps(userOps, payable(_owner));
    }

    // TODO:
    // reset gas limits after periods
    // test doing txs in different days

    /* ============ Helpers ============ */

    // fixme: somehow not working
    function _setOperationCount(SponsorPaymaster paymaster, address account, uint256 operationCount) internal {
        uint256 globalRateLimitSlot = 5; // slot number for the "globalRateLimit" mapping itself
        bytes32 globalRateLimitSlotHash = keccak256(abi.encode(account, globalRateLimitSlot)); // slot for the `operationCount` within the `RateLimitData` mapping.
        uint256 operationCountOffset = 1; // position of `operationCount` in the RateLimitData struct

        // calculate the actual storage slot
        bytes32 slot = bytes32(uint256(globalRateLimitSlotHash) + operationCountOffset);

        vm.store(
            address(paymaster),
            slot,
            bytes32(operationCount) // Make sure to properly cast the value to bytes32
        );
    }

    // deploys, registers and whitelists a Counter app
    function _createApp(uint256[4] memory appLimits) internal returns (address app) {
        // (1). deploy the counter contract
        app = address(new Counter());

        // (2). fund paymaster for Counter contract
        fundSponsorForApp(app);

        // (3). register the app
        registerApp(_owner, "CounterApp", app, appLimits);
        whitelistApp(app);
    }

    function _createApp() internal returns (address app) {
        uint256[4] memory appLimits = [
            _kintoAppRegistry.RATE_LIMIT_PERIOD(),
            _kintoAppRegistry.RATE_LIMIT_THRESHOLD(),
            _kintoAppRegistry.GAS_LIMIT_PERIOD(),
            _kintoAppRegistry.GAS_LIMIT_THRESHOLD()
        ];
        return _createApp(appLimits);
    }

    function _expectedRevertReason(string memory message) internal pure returns (bytes memory) {
        // prepare expected error message
        uint256 expectedOpIndex = 0; // Adjust as needed
        string memory expectedMessage = "AA33 reverted";
        bytes memory additionalMessage = abi.encodePacked(message);
        bytes memory expectedAdditionalData = abi.encodeWithSelector(
            bytes4(keccak256("Error(string)")), // Standard error selector
            additionalMessage
        );

        // encode the entire revert reason
        return abi.encodeWithSignature(
            "FailedOpWithRevert(uint256,string,bytes)", expectedOpIndex, expectedMessage, expectedAdditionalData
        );
    }

    /// @dev if batch is true, then we batch the increment ops
    // otherwise we do them one by one
    function _incrementCounterOps(uint256 amt, address app) internal view returns (UserOperation[] memory userOps) {
        uint256 nonce = _kintoWallet.getNonce();
        userOps = new UserOperation[](amt);
        // we iterate from 1 because the first op is whitelisting the app
        for (uint256 i = 0; i < amt; i++) {
            userOps[i] = _createUserOperation(
                address(_kintoWallet),
                address(app),
                nonce,
                privateKeys,
                abi.encodeWithSignature("increment()"),
                address(_paymaster)
            );
            nonce++;
        }
    }

    /// @dev executes `amt` transactions with only one user op per tx
    function _incrementCounterTxs(uint256 amt, address app) internal {
        UserOperation[] memory userOps = new UserOperation[](1);
        for (uint256 i = 0; i < amt; i++) {
            userOps[0] = _incrementCounterOps(amt, app)[0];
            _entryPoint.handleOps(userOps, payable(_owner));
        }
    }

    /// @dev executes transactions until the gas limit is reached
    function _incrementCounterTxsUntilGasLimit(address app) internal returns (uint256 amt) {
        uint256[4] memory appLimits = _kintoAppRegistry.getContractLimits(app);
        uint256 estimatedGasPerTx = 0;
        uint256 cumulativeGasUsed = 0;
        UserOperation[] memory userOps = new UserOperation[](1);
        while (cumulativeGasUsed < appLimits[3]) {
            if (cumulativeGasUsed + estimatedGasPerTx >= appLimits[3]) return amt;
            userOps[0] = _incrementCounterOps(1, app)[0]; // generate 1 user op
            uint256 beforeGas = gasleft();
            _entryPoint.handleOps(userOps, payable(_owner)); // execute the op
            uint256 afterGas = gasleft();
            if (amt == 0) estimatedGasPerTx = (beforeGas - afterGas);
            cumulativeGasUsed += estimatedGasPerTx;
            amt++;
        }
    }

    //// events
    event PostOpRevertReason(bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason);
}
