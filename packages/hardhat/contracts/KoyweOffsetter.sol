pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: MIT

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IToucanPoolToken.sol";
import "./IToucanCarbonOffsets.sol";
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol

interface IToucanFactory is IERC20 {
  function getContracts() external view returns (address[] memory);
  function retireAndMintCertificate(
        address beneficiary,
        string calldata beneficiaryString,
        string calldata retirementMessage,
        uint256 amount
    ) external;
}

contract KoyweOffsetter is Ownable, ReentrancyGuard {

  using Address for address payable;
  using SafeERC20 for IERC20;

  event OffsetProcessed(
    address _sender,
    IERC20 indexed _inputToken,
    IERC20 indexed _toucanToken,
    uint256 _amountInputToken,
    uint256 _amountOffset);

  // Placeholder address to identify ETH where it is treated as if it was an ERC20 token
  address constant public ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  IToucanFactory public immutable toucanFactory;
  address public immutable swapTarget;
  mapping(address => bool) public eligibleTokenAddresses;
  struct CertificateData {
    string retiringEntityString;
    address beneficiary;
    string beneficiaryString;
    string retirementMessage;
  }
  // mapping(address => mapping(address => uint256)) public balances; // user => amount they've offset with this contract since it's been deployed

  constructor(address _toucanFactory, address _swapTarget) {
    toucanFactory = IToucanFactory(_toucanFactory);
    swapTarget = _swapTarget;
  }

  function offsetFromToken(
    IERC20 _toucanToken,
    IERC20 _inputToken,
    uint256 _amountToOffset,
    uint256 _maxAmountInputToken,
    bytes memory _swapQuote,
    CertificateData memory certificateData
  )
    external
    nonReentrant
    returns (address[] memory tco2s, uint256[] memory amounts)
  {
    // we send the input tokens to the contract
    _inputToken.safeTransferFrom(msg.sender, address(this), _maxAmountInputToken);
    // we approve the swaptarget to get the tokens
    _safeApprove(_inputToken, swapTarget, _maxAmountInputToken);

    uint256 totalInputTokenSold = _buyToucanTokenForInputToken(_toucanToken, _amountToOffset, _swapQuote, _inputToken);
    require(totalInputTokenSold <= _maxAmountInputToken, "ExchangeIssuance: OVERSPENT INPUT TOKEN");

    // redeem BCT / NCT for TCO2s
    (tco2s, amounts) = autoRedeem(address(_toucanToken), _amountToOffset);

    // we return excess input token
    _returnExcessInputToken(_inputToken, _maxAmountInputToken, totalInputTokenSold);

    // retire the TCO2s to achieve offset
    autoRetire(tco2s, amounts, certificateData);
    
    // emit event
    emit OffsetProcessed(msg.sender, _inputToken, _toucanToken, totalInputTokenSold, _amountToOffset);
  }

  /**
    * Buys an exact amount of ToucanTokens using Input Token.
    * Acquires Toucan Tokens by executing the 0x swap whose callata is passed in _quote.
    *
    * @param _toucanToken          Address of the Toucan Token being bought
    * @param _amountToucanToken    Amount of Toucan Tokens to be bought
    * @param _quote                The encoded 0x transaction calldata to execute against the 0x ExchangeProxy
    * @param _inputToken           Token to use to pay for buy. Must be the sellToken of the 0x trades.
    *
    * @return totalInputTokenSold  Total amount of input token spent on this issuance
    */
  function _buyToucanTokenForInputToken(
    IERC20 _toucanToken,
    uint256 _amountToucanToken,
    bytes memory _quote,
    IERC20 _inputToken
  ) 
  internal
  returns (uint256 totalInputTokenSold)
  {
    uint256 toucanAmountBought;

    uint256 inputTokenBalanceBefore = _inputToken.balanceOf(address(this));
    
    if(isRedeemable(address(_inputToken)))
      totalInputTokenSold = _amountToucanToken;
    else {
      uint256 toucanBalanceBefore = _toucanToken.balanceOf(address(this));
      _fillQuote(_quote);
      uint256 toucanBalanceAfter = _toucanToken.balanceOf(address(this));
      toucanAmountBought = toucanBalanceAfter - toucanBalanceBefore;
      require(toucanAmountBought >= _amountToucanToken, "Offsetter: UNDERBOUGHT TOUCAN TOKENS");
      uint256 inputTokenBalanceAfter = _inputToken.balanceOf(address(this));
      totalInputTokenSold = inputTokenBalanceBefore - inputTokenBalanceAfter;
    }
  }

  /**
    * Withdraw slippage to selected address
    *
    * @param _tokens    Addresses of tokens to withdraw, specifiy ETH_ADDRESS to withdraw ETH
    * @param _to        Address to send the tokens to
    */
  function withdrawTokens(IERC20[] calldata _tokens, address payable _to) external onlyOwner payable {
    for(uint256 i = 0; i < _tokens.length; i++) {
      if(address(_tokens[i]) == ETH_ADDRESS){
        _to.sendValue(address(this).balance);
      }
      else{
        _tokens[i].safeTransfer(_to, _tokens[i].balanceOf(address(this)));
      }
    }
  }

  /**
     * Runs all the necessary approval functions required for a given ERC20 token.
     * This function can be called when a new token is added to a SetToken during a
     * rebalance.
     *
     * @param _token    Address of the token which needs approval
     * @param _spender  Address of the spender which will be approved to spend token. (Must be a whitlisted issuance module)
     */
  function approveToken(IERC20 _token, address _spender) public {
      _safeApprove(_token, _spender, type(uint256).max);
  }

  /**
    * Sets a max approval limit for an ERC20 token, provided the current allowance
    * is less than the required allownce.
    *
    * @param _token    Token to approve
    * @param _spender  Spender address to approve
    */
  function _safeApprove(IERC20 _token, address _spender, uint256 _requiredAllowance) internal {
    uint256 allowance = _token.allowance(address(this), _spender);
    if (allowance < _requiredAllowance) {
      _token.safeIncreaseAllowance(_spender, type(uint256).max - allowance);
    }
  }

  /**
    * Execute a 0x Swap quote
    *
    * @param _quote          Swap quote as returned by 0x API
    *
    */
  function _fillQuote(
     bytes memory _quote
  )
    internal
      
  {
    (bool success, bytes memory returndata) = swapTarget.call(_quote);

    // Forwarding errors including new custom errors
    // Taken from: https://ethereum.stackexchange.com/a/111187/73805
    if (!success) {
      if (returndata.length == 0) revert();
      assembly {
        revert(add(32, returndata), mload(returndata))
      }
    }
  }

  /**
    * Returns excess input token
    *
    * @param _inputToken         Address of the input token to return
    * @param _receivedAmount     Amount received by the caller
    * @param _spentAmount        Amount spent for issuance
    */
  function _returnExcessInputToken(IERC20 _inputToken, uint256 _receivedAmount, uint256 _spentAmount) internal {
    uint256 amountTokenReturn = _receivedAmount - _spentAmount;
    if (amountTokenReturn > 0) {
      _inputToken.safeTransfer(msg.sender,  amountTokenReturn);
    }
  }

  // checks address and returns if it's a pool token and can be redeemed
  // @param _erc20Address address of token to be checked
  function isRedeemable(address _erc20Address) private view returns (bool) {
    return eligibleTokenAddresses[_erc20Address];
  }

  // @description redeems an amount of NCT / BCT for TCO2
  // @param _fromToken could be the address of NCT or BCT
  // @param _amount amount to redeem
  // @notice needs to be approved on the client side
  // @returns 2 arrays, one containing the tco2s that were redeemed and another the amounts
  function autoRedeem(address _fromToken, uint256 _amount)
      public
      returns (address[] memory tco2s, uint256[] memory amounts)
  {
      require(isRedeemable(_fromToken), "Offsetter: TOKEN NON-REDEEMABLE.");

      // instantiate pool token (NCT or BCT)
      IToucanPoolToken PoolTokenImplementation = IToucanPoolToken(_fromToken);

      // auto redeem pool token for TCO2; will transfer automatically picked TCO2 to this contract
      (tco2s, amounts) = PoolTokenImplementation.redeemAuto2(_amount);
  }

  // @param _tco2s the addresses of the TCO2s to retire
  // @param _amounts the amounts to retire from the matching TCO2
  function autoRetire(
    address[] memory _tco2s,
    uint256[] memory _amounts,
    CertificateData memory _certificateData)
      public
  {
    require(_tco2s.length > 0, "You need to have at least one TCO2.");

    require(
      _tco2s.length == _amounts.length,
      "You need an equal number of addresses and amounts"
    );

    uint256 i = 0;
    while (i < _tco2s.length) {
      IToucanCarbonOffsets(_tco2s[i]).retireAndMintCertificate(_certificateData.retiringEntityString, _certificateData.beneficiary, _certificateData.beneficiaryString, _certificateData.retirementMessage, _amounts[i]);

      unchecked {
        ++i;
      }
    }
  }

  // @description you can use this to change or add eligible tokens and their addresses if needed
  // @param _tokenSymbol symbol of the token to add
  // @param _address the address of the token to add
  function setEligibleTokenAddress(address _address)
    public
    virtual
    onlyOwner
  {
    eligibleTokenAddresses[_address] = true;
  }

  // @description you can use this to delete eligible tokens  if needed
  // @param _tokenSymbol symbol of the token to add
  function deleteEligibleTokenAddress(address _address)
      public
      virtual
      onlyOwner
  {
      eligibleTokenAddresses[_address] = false;
  }

  // to support receiving ETH by default
  receive() external payable {}
  fallback() external payable {}
}
