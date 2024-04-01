// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/bridger/token-bridge-contracts/L2ArbitrumGateway.sol";
import "../../src/bridger/token-bridge-contracts/L2CustomGateway.sol";
import "../../src/bridger/token-bridge-contracts/L2ERC20Gateway.sol";
import "../../src/bridger/token-bridge-contracts/L2WethGateway.sol";

import {L2ArbitrumGatewayTest} from "@token-bridge-contracts/test-foundry/L2ArbitrumGateway.t.sol";
import {L2CustomToken} from "@token-bridge-contracts/test-foundry/L2CustomGateway.t.sol";
import {StandardArbERC20} from "@token-bridge-contracts/contracts/tokenbridge/arbitrum/StandardArbERC20.sol";
import {
    BeaconProxyFactory,
    ClonableBeaconProxy
} from "@token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {aeWETH} from "@token-bridge-contracts/contracts/tokenbridge/libraries/aeWETH.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../../src/interfaces/IKintoWallet.sol";
import "../../src/interfaces/IKintoWalletFactory.sol";

import {SharedSetup, UserOperation} from "../SharedSetup.t.sol";

contract ArbitrumBridgerTest is SharedSetup, L2ArbitrumGatewayTest {
    L2CustomGateway l2CustomGateway;
    L2ERC20Gateway l2ERC20Gateway;
    L2WethGateway l2WethGateway;
    address public l2BeaconProxyFactory;
    address public l1Token = makeAddr("l1Token");
    address public l1Weth = makeAddr("l1Weth");
    address public l2Token;
    address public l2Weth;
    address public l2CustomToken;

    event DepositSenderNotWhitelisted(address indexed _from, address indexed _to);

    function setUp() public override {
        super.setUp();

        // deploy contracts
        l2CustomGateway = new L2CustomGateway();
        l2ERC20Gateway = new L2ERC20Gateway();
        l2WethGateway = new L2WethGateway();

        // create beacon
        StandardArbERC20 standardArbERC20 = new StandardArbERC20();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(standardArbERC20));
        l2BeaconProxyFactory = address(new BeaconProxyFactory());
        BeaconProxyFactory(l2BeaconProxyFactory).initialize(address(beacon));

        ProxyAdmin pa = new ProxyAdmin();
        l2Weth = address(new TransparentUpgradeableProxy(address(new aeWETH()), address(pa), ""));
        aeWETH(payable(l2Weth)).initialize("WETH", "WETH", 18, address(l2WethGateway), l1Weth);

        // initialize
        l2CustomGateway.initialize(l1Counterpart, router);
        l2ERC20Gateway.initialize(l1Counterpart, router, l2BeaconProxyFactory);
        l2WethGateway.initialize(l1Counterpart, router, l1Weth, l2Weth);

        l2CustomToken = registerToken(); // register custom token
        l2Token = l2CustomGateway.calculateL2TokenAddress(l1Token);

        // not used here but needed for L2ArbitrumGatewayTest compliance
        address gateway = address(l2CustomGateway);
        assembly {
            sstore(l2Gateway.slot, gateway)
        }
    }

    function testFinalizeInboundTransfer_WhenL2CustomGateway_WhenReceiverIsKintoWallet_WhenSenderIsWhitelisted()
        public
    {
        sender = address(123);
        receiver = address(_kintoWallet);

        // receiver is a Kinto Wallet (walletTs should return > 0)
        vm.mockCall(
            address(address(l2CustomGateway.walletFactory())),
            abi.encodeWithSelector(IKintoWalletFactory.walletTs.selector, receiver),
            abi.encode(1)
        );

        // whitelist `sender` and try again
        whitelistFunder(sender);

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Counterpart));
        l2CustomGateway.finalizeInboundTransfer(
            l1Token, sender, receiver, amount, abi.encode(new bytes(0), new bytes(0))
        );

        // check L2 token has been created
        assertTrue(l2CustomToken.code.length > 0, "L2 token is supposed to be created");

        // check tokens have been minted to receiver;
        assertEq(ERC20(l2CustomToken).balanceOf(receiver), amount, "Invalid receiver balance");
    }

    function testFinalizeInboundTransfer_WhenL2CustomGateway_WhenReceiverIsKintoWallet_WhenSenderNotWhitelisted()
        public
    {
        // it should trigger a withdrawal back to L1

        sender = address(123);
        receiver = address(_kintoWallet);

        // receiver is a Kinto Wallet (walletTs should return > 0)
        vm.mockCall(
            address(address(l2CustomGateway.walletFactory())),
            abi.encodeWithSelector(IKintoWalletFactory.walletTs.selector, receiver),
            abi.encode(1)
        );

        // make sure `sender` is not whitelisted
        assertFalse(IKintoWallet(receiver).isFunderWhitelisted(sender));

        // check that withdrawal is triggered occurs when deposit is halted
        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(l1Token, address(l2CustomGateway), sender, 0, 0, amount);

        // check that withdrawal is triggered occurs when deposit is halted
        vm.expectEmit(true, true, true, true);
        emit DepositSenderNotWhitelisted(sender, receiver);

        // finalize deposit
        vm.etch(0x0000000000000000000000000000000000000064, address(arbSysMock).code);
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Counterpart));
        l2CustomGateway.finalizeInboundTransfer(
            l1Token, sender, receiver, amount, abi.encode(new bytes(0), new bytes(0))
        );
    }

    function testFinalizeInboundTransfer_WhenL2CustomGateway_WhenReceiverIsNotKintoWallet() public {
        // it should trigger a withdrawal back to L1

        sender = address(123);
        receiver = address(456);

        // receiver is NOT a Kinto Wallet (walletTs should return 0)
        vm.mockCall(
            address(address(l2CustomGateway.walletFactory())),
            abi.encodeWithSelector(IKintoWalletFactory.walletTs.selector, receiver),
            abi.encode(0)
        );

        // check that withdrawal is triggered occurs when deposit is halted
        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(l1Token, address(l2CustomGateway), sender, 0, 0, amount);

        // check that withdrawal is triggered occurs when deposit is halted
        vm.expectEmit(true, true, true, true);
        emit DepositSenderNotWhitelisted(sender, receiver);

        // finalize deposit
        vm.etch(0x0000000000000000000000000000000000000064, address(arbSysMock).code);
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Counterpart));
        l2CustomGateway.finalizeInboundTransfer(
            l1Token, sender, receiver, amount, abi.encode(new bytes(0), new bytes(0))
        );
    }

    // bridger L2 tests
    function testFinalizeInboundTransfer_WhenL2ERC20Gateway_WhenReceiverIsBridgerL2() public {
        l2Token = l2ERC20Gateway.calculateL2TokenAddress(l1Token);

        sender = address(123);
        receiver = l2ERC20Gateway.BRIDGER_L2();

        // receiver is not a Kinto Wallet (it's the Bridger L2)
        vm.mockCall(
            address(address(l2CustomGateway.walletFactory())),
            abi.encodeWithSelector(IKintoWalletFactory.walletTs.selector, receiver),
            abi.encode(0)
        );

        // deposit params
        bytes memory gatewayData =
            abi.encode(abi.encode(bytes("Name")), abi.encode(bytes("Symbol")), abi.encode(uint256(18)));
        bytes memory callHookData = new bytes(0);

        // finalize deposit
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Counterpart));
        l2ERC20Gateway.finalizeInboundTransfer(l1Token, sender, receiver, amount, abi.encode(gatewayData, callHookData));

        // check L2 token has been created
        assertTrue(l2Token.code.length > 0, "L2 token is supposed to be created");

        // check tokens have been minted to receiver;
        assertEq(ERC20(l2Token).balanceOf(receiver), amount, "Invalid receiver balance");
    }

    // note: overriding below tests to comply with L2ArbitrumGatewayTest which is inherited here

    function test_finalizeInboundTransfer() public override {
        console.log("test_finalizeInboundTransfer");
    }

    function test_finalizeInboundTransfer_WithCallHook() public override {
        console.log("test_finalizeInboundTransfer_WithCallHook");
    }

    function test_outboundTransfer() public override {
        console.log("test_outboundTransfer");
    }

    function test_outboundTransfer_4Args() public override {
        console.log("test_outboundTransfer_4Args");
    }

    function test_outboundTransfer_revert_NotExpectedL1Token() public override {
        console.log("test_outboundTransfer_revert_NotExpectedL1Token");
    }

    // utils

    function whitelistFunder(address _funder) public {
        address[] memory funders = new address[](1);
        funders[0] = address(_funder);

        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(address(_kintoWallet));
        _kintoWallet.setFunderWhitelist(funders, flags);

        assertTrue(IKintoWallet(address(_kintoWallet)).isFunderWhitelisted(address(_funder)));
    }

    function registerToken() internal virtual returns (address) {
        address[] memory l1Tokens = new address[](1);
        l1Tokens[0] = l1Token;

        address[] memory l2Tokens = new address[](1);
        l2Tokens[0] = address(new L2CustomToken(address(l2CustomGateway), address(l1Token)));

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Counterpart));
        l2CustomGateway.registerTokenFromL1(l1Tokens, l2Tokens);

        return l2Tokens[0];
    }
}
