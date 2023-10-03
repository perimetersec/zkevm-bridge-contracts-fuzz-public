// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.17; // TODO hardhat config compiles with 0.8.17. We should investigate upgrading this.

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAxelarGateway} from "@axelar-cgp-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IRootERC20Bridge, IERC20Metadata} from "../interfaces/root/IRootERC20Bridge.sol";
import {IRootERC20BridgeEvents, IRootERC20BridgeErrors} from "../interfaces/root/IRootERC20Bridge.sol";
import {IRootERC20BridgeAdaptor} from "../interfaces/root/IRootERC20BridgeAdaptor.sol";

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

    IRootERC20BridgeAdaptor public bridgeAdaptor;
    /// @dev The address that will be minting tokens on the child chain.
    address public childERC20Bridge;
    /// @dev The address of the token template that will be cloned to create tokens on the child chain.
    address public childTokenTemplate;
    mapping(address => address) public rootTokenToChildToken;

    /**
     * @notice Initilization function for RootERC20Bridge.
     * @param newBridgeAdaptor Address of StateSender to send bridge messages to, and receive messages from.
     * @param newChildERC20Bridge Address of child ERC20 bridge to communicate with.
     * @param newChildTokenTemplate Address of child token template to clone.
     * @dev Can only be called once.
     */
    function initialize(address newBridgeAdaptor, address newChildERC20Bridge, address newChildTokenTemplate)
        public
        initializer
    {
        if (newBridgeAdaptor == address(0) || newChildERC20Bridge == address(0) || newChildTokenTemplate == address(0))
        {
            revert ZeroAddress();
        }
        childERC20Bridge = newChildERC20Bridge;
        childTokenTemplate = newChildTokenTemplate;
        bridgeAdaptor = IRootERC20BridgeAdaptor(newBridgeAdaptor);
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

    /**
     * TODO
     */
    function deposit(IERC20Metadata rootToken, uint256 amount) external override {
        _depositERC20(rootToken, msg.sender, amount);
    }

    /**
     * TODO
     */
    function depositTo(IERC20Metadata rootToken, address receiver, uint256 amount) external override {
        _depositERC20(rootToken, receiver, amount);
    }


    // TODO update all with custom errors

    function _depositERC20(IERC20Metadata rootToken, address receiver, uint256 amount) private {
        uint256 expectedBalance = rootToken.balanceOf(address(this)) + amount;
        _deposit(rootToken, receiver, amount);
        // invariant check to ensure that the root token balance has increased by the amount deposited
        // slither-disable-next-line incorrect-equality
        require((rootToken.balanceOf(address(this)) == expectedBalance), "RootERC20Predicate: UNEXPECTED_BALANCE");
    }

    function _mapToken(IERC20Metadata rootToken) private returns (address) {
        if (address(rootToken) == address(0)) {
            revert ZeroAddress();
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
        bridgeAdaptor.sendMessage{value: msg.value}(payload, msg.sender);

        emit L1TokenMapped(address(rootToken), childToken);
        return childToken;
    }

    function _deposit(IERC20Metadata rootToken, address receiver, uint256 amount) private {
        require(receiver != address(0), "RootERC20Predicate: INVALID_RECEIVER");
        address childToken = rootTokenToChildToken[address(rootToken)];

        // The native token does not need to be mapped since it should have been mapped on initialization
        // The native token also cannot be transferred since it was received in the payable function call
        if (address(rootToken) != NATIVE_TOKEN) {
            if (childToken == address(0)) {
                childToken = _mapToken(rootToken);
            }
            // ERC20 must be transferred explicitly
            rootToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        assert(childToken != address(0));
        bytes memory payload =
            abi.encode(DEPOSIT_SIG, rootToken, msg.sender, receiver, amount);
        // TODO investigate using delegatecall to keep the axelar message sender as the bridge contract, since adaptor can change.
        bridgeAdaptor.sendMessage{value: msg.value}(payload, msg.sender);
        // TODO replace with adaptor call
        // stateSender.syncState(childERC20Predicate, abi.encode(DEPOSIT_SIG, rootToken, msg.sender, receiver, amount));
        // slither-disable-next-line reentrancy-events
        emit ERC20Deposit(address(rootToken), childToken, msg.sender, receiver, amount);
    }

    function updateBridgeAdaptor(address newBridgeAdaptor) external onlyOwner {
        if (newBridgeAdaptor == address(0)) {
            revert ZeroAddress();
        }
        bridgeAdaptor = IRootERC20BridgeAdaptor(newBridgeAdaptor);
    }
}
