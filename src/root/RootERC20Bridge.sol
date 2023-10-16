// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.21;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAxelarGateway} from "@axelar-cgp-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IRootERC20Bridge, IERC20Metadata} from "../interfaces/root/IRootERC20Bridge.sol";
import {IRootERC20BridgeEvents, IRootERC20BridgeErrors} from "../interfaces/root/IRootERC20Bridge.sol";
import {IRootERC20BridgeAdaptor} from "../interfaces/root/IRootERC20BridgeAdaptor.sol";
import {console2} from "forge-std/Test.sol";

/**
 * @notice RootERC20Bridge is a bridge that allows ERC20 tokens to be transferred from the root chain to the child chain.
 * @dev This contract is designed to be upgradeable.
 * @dev Follows a pattern of using a bridge adaptor to communicate with the child chain. This is because the underlying communication protocol may change,
 *      and also allows us to decouple vendor-specific messaging logic from the bridge logic.
 * @dev Because of this pattern, any checks or logic that is agnostic to the messaging protocol should be done in RootERC20Bridge.
 * @dev Any checks or logic that is specific to the underlying messaging protocol should be done in the bridge adaptor.
 */
contract RootERC20Bridge is
    Ownable2Step,
    Initializable,
    IRootERC20Bridge,
    IRootERC20BridgeEvents,
    IRootERC20BridgeErrors
{
    using SafeERC20 for IERC20Metadata;

    bytes32 public constant MAP_TOKEN_SIG = keccak256("MAP_TOKEN");
    bytes32 public constant DEPOSIT_SIG = keccak256("DEPOSIT");
    address public constant NATIVE_TOKEN = address(0xeee);

    IRootERC20BridgeAdaptor public rootBridgeAdaptor;
    /// @dev Used to verify source address in messages sent from child chain.
    /// @dev Stringified version of address.
    string public childBridgeAdaptor;
    /// @dev The address that will be minting tokens on the child chain.
    address public childERC20Bridge;
    /// @dev The address of the token template that will be cloned to create tokens on the child chain.
    address public childTokenTemplate;
    mapping(address => address) public rootTokenToChildToken;
    /// @dev The address of the IMX ERC20 token on L1.
    address public rootIMXToken;
    /// @dev The address of the ETH ERC20 token on L2.
    address public childETHToken;

    /**
     * @notice Initilization function for RootERC20Bridge.
     * @param newRootBridgeAdaptor Address of StateSender to send bridge messages to, and receive messages from.
     * @param newChildERC20Bridge Address of child ERC20 bridge to communicate with.
     * @param newChildBridgeAdaptor Address of child bridge adaptor to communicate with.
     * @param newChildTokenTemplate Address of child token template to clone.
     * @param newRootIMXToken Address of ECR20 IMX on the root chain.
     * @param newChildETHToken Address of ECR20 ETH on the child chain.
     * @dev Can only be called once.
     */
    function initialize(
        address newRootBridgeAdaptor,
        address newChildERC20Bridge,
        address newChildBridgeAdaptor,
        address newChildTokenTemplate, 
        address newRootIMXToken,
        address newChildETHToken)
        public
        initializer
    {
        if (newRootBridgeAdaptor == address(0) 
        || newChildERC20Bridge == address(0) 
        || newChildTokenTemplate == address(0)
        || newChildBridgeAdaptor == address(0) 
        || newRootIMXToken == address(0)
        || newChildETHToken == address(0))
        {
            revert ZeroAddress();
        }
        childERC20Bridge = newChildERC20Bridge;
        childTokenTemplate = newChildTokenTemplate;
        rootIMXToken = newRootIMXToken;
        childETHToken = newChildETHToken;
        rootBridgeAdaptor = IRootERC20BridgeAdaptor(newRootBridgeAdaptor);
        childBridgeAdaptor = Strings.toHexString(newChildBridgeAdaptor);
    }

    /**
     * @inheritdoc IRootERC20Bridge
     * @dev TODO when this becomes part of the deposit flow on a token's first bridge, this logic will need to be mostly moved into an internal function.
     *      Additionally, we need to investigate what the ordering guarantees are. i.e. if we send a map token message, then a bridge token message,
     *      in the same TX (or even very close but separate transactions), is it possible the order gets reversed? This could potentially make some
     *      first bridges break and we might then have to separate them and wait for the map to be confirmed.
     */
    function mapToken(IERC20Metadata rootToken) external payable override returns (address) {
        return _mapToken(rootToken);
    }

    function depositETH(uint256 gasAmount) external payable { //override removed?
        _depositETH(msg.sender, msg.value);
    }

    function depositToETH(address receiver, uint256 gasAmount) external payable { //override removed?
        _depositETH(receiver, msg.value);
    }

    function _depositETH(address receiver, uint256 amount, uint256 gasAmount) private {
        console2.log('start balance');
        console2.logUint(address(this).balance);
        _deposit(IERC20Metadata(NATIVE_TOKEN), receiver, amount, gasAmount);
        //@TODO can we do an invariant check here?
        console2.log('end balance');

        console2.logUint(address(this).balance);


        // invariant check to ensure that the root native balance has increased by the amount deposited
        // if (address(msg.sender).balance != expectedBalance) {
        //     revert BalanceInvariantCheckFailed(address(this).balance, expectedBalance);
        // }
    }

    /**
     * @inheritdoc IRootERC20Bridge
     */
    function deposit(IERC20Metadata rootToken, uint256 amount) external payable override {
        _depositERC20(rootToken, msg.sender, amount);
    }

    /**
     * @inheritdoc IRootERC20Bridge
     */
    function depositTo(IERC20Metadata rootToken, address receiver, uint256 amount) external payable override {
        _depositERC20(rootToken, receiver, amount);
    }

    function _depositERC20(IERC20Metadata rootToken, address receiver, uint256 amount) private {
        uint256 expectedBalance = rootToken.balanceOf(address(this)) + amount;
        _deposit(rootToken, receiver, amount);
        // invariant check to ensure that the root token balance has increased by the amount deposited
        // slither-disable-next-line incorrect-equality
        if (rootToken.balanceOf(address(this)) != expectedBalance) {
            revert BalanceInvariantCheckFailed(rootToken.balanceOf(address(this)), expectedBalance);
        }
    }

    function _mapToken(IERC20Metadata rootToken) private returns (address) {
        if(msg.value == 0) {
            revert NoGas();
        }
        if (address(rootToken) == address(0)) {
            revert ZeroAddress();
        }
        if (address(rootToken) == rootIMXToken) {
            revert CantMapIMX();
        }
        if (rootTokenToChildToken[address(rootToken)] != address(0)) {
            revert AlreadyMapped();
        }

        address childBridge = childERC20Bridge;

        address childToken =
            Clones.predictDeterministicAddress(childTokenTemplate, keccak256(abi.encodePacked(rootToken)), childBridge);

        rootTokenToChildToken[address(rootToken)] = childToken;

        bytes memory payload =
            abi.encode(MAP_TOKEN_SIG, rootToken, rootToken.name(), rootToken.symbol(), rootToken.decimals());
        // TODO investigate using delegatecall to keep the axelar message sender as the bridge contract, since adaptor can change.
        rootBridgeAdaptor.sendMessage{value: msg.value}(payload, msg.sender);

        emit L1TokenMapped(address(rootToken), childToken);
        return childToken;
    }

    function _deposit(IERC20Metadata rootToken, address receiver, uint256 amount) private {
        console2.log("_deposit ---------------");
        if(msg.value == 0) {
            revert NoGas();
        }

        if (receiver == address(0) || address(rootToken) == address(0)) {
            revert ZeroAddress();
        }

        address childToken;

        // The native token does not need to be mapped since it should have been mapped on initialization
        // The native token also cannot be transferred since it was received in the payable function call
        // TODO We can call _mapToken here, but ordering in the GMP is not guaranteed.
        //      Therefore, we need to decide how to handle this and it may be a UI decision to wait until map token message is executed on child chain.
        //      Discuss this, and add this decision to the design doc.
        if (address(rootToken) != NATIVE_TOKEN) {  

        console2.log("!NATIVE_TOKEN");


            if (address(rootToken) != rootIMXToken) {
                childToken = rootTokenToChildToken[address(rootToken)];
                if (childToken == address(0)) {
                    revert NotMapped();
                }
            }
            
            // ERC20 must be transferred explicitly
            rootToken.safeTransferFrom(msg.sender, address(this), amount);
        }

        console2.logBytes32(DEPOSIT_SIG);
        console2.logAddress(address(rootToken));
        console2.logAddress(msg.sender);
        console2.logAddress(address(receiver));
        console2.logUint(amount);
        
        // Deposit sig, root token address, depositor, receiver, amount
        bytes memory payload = abi.encode(DEPOSIT_SIG, rootToken, msg.sender, receiver, amount);
        // TODO investigate using delegatecall to keep the axelar message sender as the bridge contract, since adaptor can change.

        console2.logBytes(payload);

        gasService.payNativeGasForContractCall{ value: msg.value }(
            address(this),
            destinationChain,
            destinationAddress,
            payload,
            msg.sender
        );

        //@TODO need to minus the bridge amount from the gas otherwise we're sending the whole amount to axelar
        rootBridgeAdaptor.sendMessage{value: msg.value}(payload, msg.sender);

        if (address(rootToken) == NATIVE_TOKEN) {
            console2.log("emit NativeDeposit");
            emit NativeDeposit(address(rootToken), childETHToken, msg.sender, receiver, amount);
        } else if (address(rootToken) == rootIMXToken) {
            emit IMXDeposit(address(rootToken), msg.sender, receiver, amount);
        } else {
            emit ERC20Deposit(address(rootToken), childToken, msg.sender, receiver, amount);
        }
    }

    function updateRootBridgeAdaptor(address newRootBridgeAdaptor) external onlyOwner {
        if (newRootBridgeAdaptor == address(0)) {
            revert ZeroAddress();
        }
        rootBridgeAdaptor = IRootERC20BridgeAdaptor(newRootBridgeAdaptor);
    }
}
