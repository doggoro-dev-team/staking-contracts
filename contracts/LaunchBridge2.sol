// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import { IDAI } from "./interface/IDAI.sol";
import { IDsrManager } from "./interface/IDsrManager.sol";
import { ILido } from "./interface/ILido.sol";
import { IPot } from "./interface/IPot.sol";
import { Math } from './library/Math.sol';

/**
 * 放弃LSD收益的
 */

contract LaunchBridge2 is
  UUPSUpgradeable,
  Ownable2StepUpgradeable,
  PausableUpgradeable
{
  mapping(address => uint256) public ethShares;
  uint256 public totalETHShares;

  mapping(address => uint256) public usdShares;
  uint256 public totalUSDShares;

  address public staker;

  uint256 constant EMERGENCY_WITHDRAW_TIMESTAMP = 1717200000; // June 1, 2024

  ILido public constant LIDO =
    ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84); // stETH
  IDsrManager public constant DSR_MANAGER =
    IDsrManager(0x373238337Bfe1146fb49989fc222523f83081dDb);
  IDAI public constant DAI = IDAI(0x6B175474E89094C44Da98b954EedeAC495271d0F);

  address internal constant _INITIAL_TOKEN_HOLDER =
    0x000000000000000000000000000000000000dEaD;
  uint256 internal constant _RAY = 10 ** 27;
  uint256 internal constant _INITIAL_DEPOSIT_AMOUNT = 1000;

  struct Proposal {
    address to;
    bytes32 codehash;
  }

  // Timer for Admin Proxy updates via `proposeUpgrade` / `upgradeTo` codepath.
  uint public proposedUpgradeReadyAt;
  // Address to be upgraded to.
  Proposal public proposedUpgrade;

  // Timer for Bridge Transition updates via `proposeTransition` / `enableTransition` codepath.
  uint public proposedBridgeReadyAt;

  event ETHDeposited(address indexed user, uint256 shares, uint256 amount);
  event USDDeposited(
    address indexed user,
    uint256 shares,
    uint256 amount,
    uint256 daiAmount
  );
  event Withdraw(
    address indexed user,
    uint256 ethAmount,
    uint256 stETHAmount,
    uint256 daiAmount
  );
  event WithdrawInterest(
    address indexed user,
    uint256 ethAmount,
    uint256 stETHAmount,
    uint256 daiAmount
  );
  event ProposeUpgrade(address upgradeTo);
  event ResetProposedUpgrade();

  error CallerIsNotStaker();
  error InsufficientFunds();
  error ZeroDeposit();
  error ZeroSharesIssued();
  error SharesNotInitiated();

  constructor() {
    _disableInitializers();
  }

  function initialize(address _staker) external initializer {
    __UUPSUpgradeable_init();
    __Ownable2Step_init();
    __Pausable_init();

    _pause();

    staker = _staker;

    DAI.approve(address(DSR_MANAGER), type(uint256).max);
  }

  /*/////////////////////////
             UPGRADES
    /////////////////////////*/

  /**
   * @notice Proposes a new upgrade, which will begin a 24 hr timelock
   */
  function proposeUpgrade(address upgradeTo) external onlyOwner {
    proposedUpgradeReadyAt = block.timestamp + 1 days;
    proposedUpgrade = Proposal({ to: upgradeTo, codehash: upgradeTo.codehash });

    emit ProposeUpgrade(upgradeTo);
  }

  /**
   * @notice Cancel a proposed upgrade
   */
  function cancelProposedUpgrade() external onlyOwner {
    require(proposedUpgradeReadyAt > 0, "No upgrade scheduled");

    _resetProposedUpgrade();
  }

  function _resetProposedUpgrade() internal {
    proposedUpgradeReadyAt = 0;
    proposedUpgrade = Proposal(address(0), bytes32(0));

    emit ResetProposedUpgrade();
  }

  /// This function can be overriden by implementers (as we do) in order
  /// to provide additional logic during an upgrade. Here we use it to introduce
  /// a timelock on all upgrades via the `proposeUpgrade` function. Any upgrades
  /// without first going through the timelock now will revert.
  function _authorizeUpgrade(address target) internal override onlyOwner {
    address proposedAddress = proposedUpgrade.to;
    bytes32 proposedCodehash = proposedUpgrade.codehash;

    require(proposedAddress != address(0x00), "No proposed upgrade");
    require(block.timestamp > proposedUpgradeReadyAt, "Upgrade not ready");

    require(target == proposedAddress, "Not proposed upgrade address");
    require(
      target.codehash == proposedCodehash,
      "Not proposed upgrade codehash"
    );

    _resetProposedUpgrade();
  }

  /**
   * @notice Pause deposits to the bridge (admin only)
   */
  function pause() external onlyOwner {
    _pause();
  }

  /**
   * @notice Unpause deposits to the bridge (admin only)
   */
  function unpause() external onlyOwner {
    if (totalETHShares == 0 && totalUSDShares == 0) {
      revert SharesNotInitiated();
    }

    _unpause();
  }

  /**
   * @notice Set approved staker (admin only)
   * @param _staker New staker address
   */
  function setStaker(address _staker) public onlyOwner {
    staker = _staker;
  }

  /**
   * @notice Open bridge to accept deposits; accept initial ETH and DAI deposit to initiate the shares accounting (admin only)
   * @param from Initial depositor
   * @param nonce Permit signature nonce
   * @param v Permit signature v parameter
   * @param r Permit signature r parameter
   * @param s Permit signature s parameter
   */
  function open(
    address from,
    uint256 nonce,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external payable onlyOwner {
    DAI.permit(from, address(this), nonce, type(uint256).max, true, v, r, s);
    DAI.transferFrom(from, address(this), _INITIAL_DEPOSIT_AMOUNT);

    uint256 ethBalance = address(this).balance;
    uint256 daiBalance = DAI.balanceOf(address(this));

    assert(totalETHShares == 0 && totalUSDShares == 0);
    assert(
      ethBalance >= _INITIAL_DEPOSIT_AMOUNT &&
        daiBalance >= _INITIAL_DEPOSIT_AMOUNT
    );
    _mintETHShares(_INITIAL_TOKEN_HOLDER, ethBalance);
    _mintUSDShares(_INITIAL_TOKEN_HOLDER, daiBalance);

    _unpause();
  }

  /**
   * @notice Withdraw interest by owner
   */
  function withdrawInterest() external onlyOwner {
    uint256 contractETHBalance = address(this).balance;
    uint256 ethAmountToMove = totalETHBalance() - totalETHShares;
    uint256 stETHAmountToMove;
    if (ethAmountToMove > contractETHBalance) {
      stETHAmountToMove = ethAmountToMove - contractETHBalance;
      ethAmountToMove = contractETHBalance;
    }

    uint256 contractDAIBalance = DAI.balanceOf(address(this));
    uint256 daiAmountToMove = totalUSDBalance() - totalUSDShares;
    if (daiAmountToMove > contractDAIBalance) {
      DSR_MANAGER.exit(address(this), daiAmountToMove - contractDAIBalance);
    }

    if (stETHAmountToMove > 0) {
      LIDO.transfer(msg.sender, stETHAmountToMove);
    }
    if (daiAmountToMove > 0) {
      DAI.transfer(msg.sender, daiAmountToMove);
    }
    if (ethAmountToMove > 0) {
      payable(msg.sender).transfer(ethAmountToMove);
    }

    emit WithdrawInterest(
      msg.sender,
      ethAmountToMove,
      stETHAmountToMove,
      daiAmountToMove
    );
  }

  /**
   * @notice Get the user balance in ETH and USD pool
   * @dev Does not update DSR yield
   * @param user User address
   * @return ethBalance User's ETH balance, usdBalance User's USD balance
   */
  function balanceOf(
    address user
  ) external view returns (uint256 ethBalance, uint256 usdBalance) {
    ethBalance = ethShares[user];
    usdBalance = usdShares[user];
  }

  /**
   * @notice Get the current ETH pool balance
   * @return Pooled ETH balance between buffered balance and deposited Lido balance
   */
  function totalETHBalance() public view returns (uint256) {
    return address(this).balance + LIDO.balanceOf(address(this));
  }

  /**
   * @notice Get the current USD pool balance
   * @dev Does not update DSR yield
   * @return Pooled USD balance between buffered balance and deposited DSR balance
   */
  function totalUSDBalanceNoUpdate() public view returns (uint256) {
    IPot pot = IPot(DSR_MANAGER.pot());
    uint256 chi = Math.rmul(
      Math.rpow(pot.dsr(), block.timestamp - pot.rho(), _RAY),
      pot.chi()
    );
    return
      DAI.balanceOf(address(this)) +
      Math.rmul(DSR_MANAGER.pieOf(address(this)), chi);
  }

  /**
   * @notice Get the current USD pool balance
   * @return Pooled USD balance between buffered balance and deposited DSR balance
   */
  function totalUSDBalance() public returns (uint256) {
    return DAI.balanceOf(address(this)) + DSR_MANAGER.daiBalance(address(this));
  }

  /*/////////////////////////
             DEPOSITS
    /////////////////////////*/

  receive() external payable {
    depositETH();
  }

  /**
   * @notice Deposit ETH to the ETH pool
   */
  function depositETH() public payable {
    if (msg.value == 0) {
      revert ZeroDeposit();
    }
    _recordDepositETHAfterTransfer(msg.value);
  }

  /**
   * @notice Deposit DAI to the USD pool
   * @param daiAmount Amount to deposit in DAI (wad)
   */
  function depositDAI(uint256 daiAmount) public {
    if (daiAmount == 0) {
      revert ZeroDeposit();
    }
    _recordDepositUSDBeforeTransfer(daiAmount, daiAmount);

    DAI.transferFrom(msg.sender, address(this), daiAmount);
  }

  /**
   * @notice Deposit DAI to the USD pool with a permit signature
   * @param daiAmount Amount to deposit in DAI (wad)
   * @param nonce Permit signature nonce
   * @param expiry Permit signature expiry timestamp
   * @param v Permit signature v parameter
   * @param r Permit signature r parameter
   * @param s Permit signature s parameter
   */
  function depositDAIWithPermit(
    uint256 daiAmount,
    uint256 nonce,
    uint256 expiry,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external {
    DAI.permit(msg.sender, address(this), nonce, expiry, true, v, r, s);
    depositDAI(daiAmount);
  }

  /**
   * @notice Mint new ETH shares from new deposit after deposit has been made
   * @param amount Amount deposited in ETH
   */
  function _recordDepositETHAfterTransfer(uint256 amount) internal {
    _recordDepositETH(amount, true);
  }

  /**
   * @notice Mint new USD shares from new deposit before deposit has been made
   * @param depositedAmount Amount deposited in USD (wad)
   * @param daiAmount Amount of DAI obtained after conversion (wad)
   */
  function _recordDepositUSDBeforeTransfer(
    uint256 depositedAmount,
    uint256 daiAmount
  ) internal {
    _recordDepositUSD(depositedAmount, daiAmount, false);
  }

  /**
   * @notice Mint new ETH shares from new deposit
   * @param depositedAmount Amount deposited in ETH (wad)
   * @param alreadyDeposited The amount has already been deposited to the contract
   */
  function _recordDepositETH(
    uint256 depositedAmount,
    bool alreadyDeposited
  ) internal whenNotPaused {
    uint256 _totalETHBalance = totalETHBalance();
    if (alreadyDeposited) {
      _totalETHBalance = _totalETHBalance - depositedAmount;
    }
    uint256 sharesToIssue = depositedAmount;
    if (sharesToIssue == 0) {
      revert ZeroSharesIssued();
    }

    _mintETHShares(msg.sender, sharesToIssue);

    emit ETHDeposited(msg.sender, sharesToIssue, depositedAmount);
  }

  /**
   * @notice Mint new USD shares from new deposit
   * @param depositedAmount Amount deposited in USD (wad)
   * @param daiAmount Amount of DAI obtained after conversion (wad)
   * @param alreadyDeposited The amount has already been deposited to the contract
   */
  function _recordDepositUSD(
    uint256 depositedAmount,
    uint256 daiAmount,
    bool alreadyDeposited
  ) internal whenNotPaused {
    uint256 _totalUSDBalance = totalUSDBalance();
    if (alreadyDeposited) {
      _totalUSDBalance = _totalUSDBalance - daiAmount;
    }
    uint256 sharesToIssue = daiAmount;
    if (sharesToIssue == 0) {
      revert ZeroSharesIssued();
    }

    _mintUSDShares(msg.sender, sharesToIssue);

    emit USDDeposited(msg.sender, sharesToIssue, depositedAmount, daiAmount);
  }

  /**
   * @notice Mint ETH shares
   * @param user User address
   * @param shares Number of ETH shares to mint
   */
  function _mintETHShares(address user, uint256 shares) internal {
    ethShares[user] += shares;
    totalETHShares += shares;
  }

  /**
   * @notice Mint USD shares
   * @param user User address
   * @param shares Number of USD shares to mint
   */
  function _mintUSDShares(address user, uint256 shares) internal {
    usdShares[user] += shares;
    totalUSDShares += shares;
  }

  /**
   * @notice Burn ETH shares
   * @param user User address
   * @param shares Number of ETH shares to burn
   */
  function _burnETHShares(address user, uint256 shares) internal {
    ethShares[user] -= shares;
    totalETHShares -= shares;
  }

  /**
   * @notice Burn USD shares
   * @param user User address
   * @param shares Number of USD shares to burn
   */
  function _burnUSDShares(address user, uint256 shares) internal {
    usdShares[user] -= shares;
    totalUSDShares -= shares;
  }

  /*/////////////////////////
              STAKING
    /////////////////////////*/

  /**
   * @notice Stake pooled ETH funds by submiting ETH to Lido
   * @param amount Amount in ETH to stake (wad)
   */
  function stakeETH(uint256 amount) external {
    if (msg.sender != staker) {
      revert CallerIsNotStaker();
    }
    if (amount > address(this).balance) {
      revert InsufficientFunds();
    }

    LIDO.submit{ value: amount }(address(0));
  }

  /**
   * @notice Stake pooled USD funds by depositing DAI into the Maker DSR
   * @param amount Amount in DAI to stake (usd)
   */
  function stakeUSD(uint256 amount) external {
    if (msg.sender != staker) {
      revert CallerIsNotStaker();
    }
    if (amount > DAI.balanceOf(address(this))) {
      revert InsufficientFunds();
    }

    DSR_MANAGER.join(address(this), amount);
  }

  /// Allows a user to reclaim their ETH / DAI when a proposal or upgrade
  /// is live. Reverts otherwise.
  function withdrawAndLosePoints() external {
    require(
      proposedBridgeReadyAt > 0 || proposedUpgradeReadyAt > 0,
      "No upgrade scheduled"
    );
    _withdraw();
  }

  /// In the event multisig keys are lost, users can reclaim their funds after the contract
  /// has expired.
  function emergencyWithdraw() external {
    require(
      block.timestamp > EMERGENCY_WITHDRAW_TIMESTAMP,
      "Emergency timestamp not reached"
    );
    _withdraw();
  }

  function _withdraw() internal {
    (uint ethAmountToMove, uint stETHAmountToMove) = _moveETH(msg.sender);
    uint daiAmountToMove = _moveUSD(msg.sender);

    if (stETHAmountToMove > 0) {
      LIDO.transfer(msg.sender, stETHAmountToMove);
    }
    if (daiAmountToMove > 0) {
      DAI.transfer(msg.sender, daiAmountToMove);
    }
    if (ethAmountToMove > 0) {
      payable(msg.sender).transfer(ethAmountToMove);
    }

    emit Withdraw(
      msg.sender,
      ethAmountToMove,
      stETHAmountToMove,
      daiAmountToMove
    );
  }

  /**
   * @notice Move user's portion of pooled ETH by the amount of shares
   * @param user User address
   */
  // NB: This function was refactored to return the assets it'd move around, and
  // the caller is responsible for executing the actual transfer.
  function _moveETH(
    address user
  ) internal returns (uint ethAmountToMove, uint stETHAmountToMove) {
    uint256 userETHShares = ethShares[user];
    if (userETHShares > 0) {
      ethAmountToMove = userETHShares;
      _burnETHShares(user, userETHShares);

      /*
        If there are insufficient ETH funds in the bridge to cover the user's share,
        then we need to start moving StETH.
      */
      uint256 contractETHBalance = address(this).balance;
      if (ethAmountToMove > contractETHBalance) {
        stETHAmountToMove = ethAmountToMove - contractETHBalance;
        ethAmountToMove = contractETHBalance;
      }
    }
  }

  /**
   * @notice Move user's portion of pooled USD by the amount of shares
   * @param user User address
   */
  function _moveUSD(address user) internal returns (uint daiAmountToMove) {
    uint256 userUSDShares = usdShares[user];
    if (userUSDShares > 0) {
      daiAmountToMove = userUSDShares;
      _burnUSDShares(user, userUSDShares);

      /*
               If there are insufficient DAI funds in the bridge to cover the user's share,
               then we need to start withdrawing DAI from the DSR.
            */
      uint256 contractDAIBalance = DAI.balanceOf(address(this));
      if (daiAmountToMove > contractDAIBalance) {
        DSR_MANAGER.exit(address(this), daiAmountToMove - contractDAIBalance);
      }
    }
  }


}
