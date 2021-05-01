// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

/**
 * This code contains elements of ERC20BurnableUpgradeable.sol https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/master/contracts/token/ERC20/ERC20BurnableUpgradeable.sol
 * Those have been inlined for the purpose of gas optimization.
 */

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @title ProofOfHumanity Interface
 * @dev See https://github.com/Proof-Of-Humanity/Proof-Of-Humanity.
 */
interface IProofOfHumanity {
  function isRegistered(address _submissionID)
    external
    view
    returns (
      bool registered
    );
}


/**
 * @title Poster Interface
 * @dev See https://github.com/auryn-macmillan/poster
 */
interface IPoster {
  event NewPost(bytes32 id, address user, string content);

  function post(string memory content) external;
}


/**
 * @title Universal Basic Income
 * @dev UBI is an ERC20 compatible token that is connected to a Proof of Humanity registry.
 *
 * Tokens are issued and drip over time for every verified submission on a Proof of Humanity registry.
 * The accrued tokens are updated directly on every wallet using the `balanceOf` function.
 * The tokens get effectively minted and persisted in memory when someone interacts with the contract doing a `transfer` or `burn`.
 */
contract UBI is Initializable {

  /* Events */

  /**
   * @dev Emitted when `value` tokens are moved from one account (`from`) to another (`to`).
   *
   * Note that `value` may be zero.
   * Also note that due to continuous minting we cannot emit transfer events from the address 0 when tokens are created.
   * In order to keep consistency, we decided not to emit those events from the address 0 even when minting is done within a transaction.
   */
  event Transfer(address indexed from, address indexed to, uint256 value);

  /**
   * @dev Emitted when the allowance of a `spender` for an `owner` is set by
   * a call to {approve}. `value` is the new allowance.
   */
  event Approval(address indexed owner, address indexed spender, uint256 value);

  using SafeMath for uint256;

  /* Storage */

  mapping (address => uint256) private balance;

  mapping (address => mapping (address => uint256)) public allowance;

  /**@dev M0 supply marker
  * M0 should be updated after..
  * a) adding new PoH
  * b) revoking active PoH
  *
  * If accrued per sec rate is changed,
  * It'll fluctuate +- "real" total supply
  */
  uint256 public totalSupply; // Solidity upgrade didn't allow name change.

  /// @dev Name of the token.
  string public name;

  /// @dev Symbol of the token.
  string public symbol;

  /// @dev Number of decimals of the token.
  uint8 public decimals;

  /// @dev How many tokens per second will be minted for every valid human.
  uint256 public accruedPerSecond;

  /// @dev The contract's governor.
  address public governor;

  /// @dev The Proof Of Humanity registry to reference.
  IProofOfHumanity public proofOfHumanity;

  /// @dev Timestamp since human started accruing.
  mapping(address => uint256) public accruedSince;

  /// @dev Number of active Humans accruing UBI, Updated after adding / revoking PoH
  uint256 public activeVerifiedHumans;

  /// @dev Timestamp of last M0 update
  uint256 public lastSupplyUpdate; // same as accruedSince but for M0 supply

  /**@dev Total Supply of UBI
  * @notice
  */
  function realTotalSupply() public view returns(uint){
    // NOT using SafeMath for internal is OK?
    return totalSupply + ((block.timestamp - lastSupplyUpdate) * (activeVerifiedHumans * accruedPerSecond));
  }

  struct StreamInfo {
    uint256 streamedSince;
    uint256 totalIncoming;
    uint256 totalOutgoing;
    address[] outgoingRecipients;
    mapping(address => uint256) streams;
  }

  /// @dev Information about UBI streams to/from accounts.
  mapping(address => StreamInfo) public streamInfo;

  /* Modifiers */

  /// @dev Verifies that the sender has ability to modify governed parameters.
  modifier onlyByGovernor() {
    require(governor == msg.sender, "The caller is not the governor.");
    _;
  }

  /* Initializer */

  /** @dev Constructor.
  *  @param _initialSupply for the UBI coin including all decimals.
  *  @param _name for UBI coin.
  *  @param _symbol for UBI coin ticker.
  *  @param _accruedPerSecond How much of the token is accrued per block.
  *  @param _proofOfHumanity The Proof Of Humanity registry to reference.
  */
  function initialize(uint256 _initialSupply, string memory _name, string memory _symbol, uint256 _accruedPerSecond, IProofOfHumanity _proofOfHumanity) public initializer {
    name = _name;
    symbol = _symbol;
    decimals = 18;

    accruedPerSecond = _accruedPerSecond;
    proofOfHumanity = _proofOfHumanity;
    governor = msg.sender;

    balance[msg.sender] = _initialSupply;
    totalSupply = _initialSupply;
  }

  /* External */

  /** @dev Starts accruing UBI for a registered submission.
  *  @param _human The submission ID.
  */
  function startAccruing(address _human) external {
    require(proofOfHumanity.isRegistered(_human), "The submission is not registered in Proof Of Humanity.");
    require(accruedSince[_human] == 0, "The submission is already accruing UBI.");
    accruedSince[_human] = block.timestamp;
    totalSupply = totalSupply.add(activeVerifiedHumans.mul(accruedPerSecond).mul(block.timestamp.sub(lastSupplyUpdate)));
    activeVerifiedHumans++;
    lastSupplyUpdate = block.timestamp;
  }

  /** @dev Allows anyone to report a submission that
  *  should no longer receive UBI due to removal from the
  *  Proof Of Humanity registry. The reporter receives any
  *  leftover accrued UBI.
  *  @param _human The submission ID.
  */
  function reportRemoval(address _human) external  {
    require(!proofOfHumanity.isRegistered(_human), "The submission is still registered in Proof Of Humanity.");
    StreamInfo storage humanInfo = streamInfo[_human];
    require(accruedSince[_human] != 0, "The submission is not accruing UBI.");
    uint256 _slash; // total value recovered
    uint256 _totalClosed; // sum of UBI units
    for (uint256 i = 0; i < humanInfo.outgoingRecipients.length; i++) {
      address _addr = humanInfo.outgoingRecipients[i];
      uint256 _drip = humanInfo.streams[_addr]; // units in this stream >=0
      StreamInfo storage outflowInfo = streamInfo[_addr];
      outflowInfo.totalIncoming -= _drip; // subtract units
      _slash = _slash.add(_drip.mul(block.timestamp.sub(outflowInfo.streamedSince)));
      if (outflowInfo.totalIncoming == 0) {
        outflowInfo.streamedSince = 0;
      }
      _totalClosed = _totalClosed.add(_drip); // for final check
      humanInfo.streams[_addr] = 0;
      emit Revoked(_human, _addr); // emit revoked event
    }
    delete humanInfo.outgoingRecipients;
    require(humanInfo.totalOutgoing == _totalClosed, "Stream: Unable to close all outgoing streams.");
    _slash = _slash.add(accruedPerSecond.sub(humanInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[_human])));
    accruedSince[_human] = 0;
    humanInfo.totalOutgoing = 0;
    balance[msg.sender] = balance[msg.sender].add(_slash); // reward msg sender
    totalSupply = totalSupply.add(activeVerifiedHumans.mul(accruedPerSecond).mul(block.timestamp.sub(lastSupplyUpdate)));
    activeVerifiedHumans--;
    lastSupplyUpdate = block.timestamp;
  }

  /** @dev Changes `governor` to `_governor`.
  *  @param _governor The address of the new governor.
  */
  function changeGovernor(address _governor) external onlyByGovernor {
    governor = _governor;
  }

  /** @dev Changes `proofOfHumanity` to `_proofOfHumanity`.
  *  @param _proofOfHumanity Registry that meets interface of Proof of Humanity.
  */
  function changeProofOfHumanity(IProofOfHumanity _proofOfHumanity) external onlyByGovernor {
    proofOfHumanity = _proofOfHumanity;
  }

  /** @dev Transfers `_amount` to `_recipient` and withdraws accrued tokens.
  *  @param _recipient The entity receiving the funds.
  *  @param _amount The amount to transfer in base units.
  */
  function transfer(address _recipient, uint256 _amount) public returns (bool) {
    uint256 _accrued;
    StreamInfo storage senderInfo = streamInfo[msg.sender];
    if (accruedSince[msg.sender] != 0 && proofOfHumanity.isRegistered(msg.sender)) {
      _accrued = accruedPerSecond.sub(senderInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[msg.sender]));
      accruedSince[msg.sender] = block.timestamp;
    }
    if (senderInfo.streamedSince != 0) {
      _accrued = _accrued.add(senderInfo.totalIncoming.mul(block.timestamp.sub(senderInfo.streamedSince)));
      senderInfo.streamedSince = block.timestamp;
    }
    balance[msg.sender] = balance[msg.sender].add(_accrued).sub(_amount, "ERC20: transfer amount exceeds balance");
    balance[_recipient] = balance[_recipient].add(_amount);
    emit Transfer(msg.sender, _recipient, _amount);
    return true;
  }

  /** @dev Transfers `_amount` from `_sender` to `_recipient` and withdraws accrued tokens.
  *  @param _sender The entity to take the funds from.
  *  @param _recipient The entity receiving the funds.
  *  @param _amount The amount to transfer in base units.
  */
  function transferFrom(address _sender, address _recipient, uint256 _amount) public returns (bool) {
    if(allowance[_sender][msg.sender] != type(uint256).max){
      allowance[_sender][msg.sender] = allowance[_sender][msg.sender].sub(_amount, "ERC20: transfer amount exceeds allowance");
    }
    uint256 _accrued;
    StreamInfo storage senderInfo = streamInfo[_sender];
    if (accruedSince[_sender] != 0 && proofOfHumanity.isRegistered(_sender)) {
      _accrued = accruedPerSecond.sub(senderInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[_sender]));
      accruedSince[_sender] = block.timestamp;
    }
    if (senderInfo.streamedSince != 0) {
      _accrued = _accrued.add(senderInfo.totalIncoming.mul(block.timestamp.sub(senderInfo.streamedSince)));
      senderInfo.streamedSince = block.timestamp;
    }
    balance[_sender] = balance[_sender].add(_accrued).sub(_amount, "ERC20: transfer amount exceeds balance");
    balance[_recipient] += _amount;
    emit Transfer(_sender, _recipient, _amount);
    return true;
  }

  /** @dev Approves `_spender` to spend `_amount`.
  *  @param _spender The entity allowed to spend funds.
  *  @param _amount The amount of base units the entity will be allowed to spend.
  */
  function approve(address _spender, uint256 _amount) public returns (bool) {
    allowance[msg.sender][_spender] = _amount;
    emit Approval(msg.sender, _spender, _amount);
    return true;
  }

  /** @dev Increases the `_spender` allowance by `_addedValue`.
  *  @param _spender The entity allowed to spend funds.
  *  @param _addedValue The amount of extra base units the entity will be allowed to spend.
  */
  function increaseAllowance(address _spender, uint256 _addedValue) public returns (bool) {
    uint256 newAllowance = allowance[msg.sender][_spender].add(_addedValue);
    allowance[msg.sender][_spender] = newAllowance;
    emit Approval(msg.sender, _spender, newAllowance);
    return true;
  }

  /** @dev Decreases the `_spender` allowance by `_subtractedValue`.
  *  @param _spender The entity whose spending allocation will be reduced.
  *  @param _subtractedValue The reduction of spending allocation in base units.
  */
  function decreaseAllowance(address _spender, uint256 _subtractedValue) public returns (bool) {
    uint256 newAllowance = allowance[msg.sender][_spender].sub(_subtractedValue, "ERC20: decreased allowance below zero");
    allowance[msg.sender][_spender] = newAllowance;
    emit Approval(msg.sender, _spender, newAllowance);
    return true;
  }

  /** @dev Burns `_amount` of tokens and withdraws accrued tokens.
  *  @param _amount The quantity of tokens to burn in base units.
  */
  function burn(uint256 _amount) public {
    uint256 _accrued;
    StreamInfo storage senderInfo = streamInfo[msg.sender];
    if (accruedSince[msg.sender] != 0 && proofOfHumanity.isRegistered(msg.sender)) {
      _accrued = accruedPerSecond.sub(senderInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[msg.sender]));
      accruedSince[msg.sender] = block.timestamp;
    }
    if (senderInfo.streamedSince != 0) {
      _accrued = _accrued.add(senderInfo.totalIncoming.mul(block.timestamp.sub(senderInfo.streamedSince)));
      senderInfo.streamedSince = block.timestamp;
    }
    balance[msg.sender] = (balance[msg.sender].add(_accrued)).sub(_amount, "ERC20: Burn amount exceeds balance");
    totalSupply = totalSupply.sub(_amount);
    emit Transfer(msg.sender, address(0), _amount);
  }

  /** @dev Burns `_amount` of tokens and posts content in a Poser contract.
  *  @param _amount The quantity of tokens to burn in base units.
  *  @param _poster the address of the poster contract.
  *  @param content bit of strings to signal.
  */
  function burnAndPost(uint256 _amount, address _poster, string memory content) public {
    burn(_amount);
    IPoster poster = IPoster(_poster);
    poster.post(content);
  }

  /** @dev Burns `_amount` of tokens from `_account` and withdraws accrued tokens.
  *  @param _account The entity to burn tokens from.
  *  @param _amount The quantity of tokens to burn in base units.
  */
  function burnFrom(address _account, uint256 _amount) public {
    uint256 _accrued;
    StreamInfo storage _streamInfo = streamInfo[_account];
    if (accruedSince[_account] != 0 && proofOfHumanity.isRegistered(_account)) {
      _accrued = accruedPerSecond.sub(_streamInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[_account]));
      accruedSince[_account] = block.timestamp;
    }
    if (_streamInfo.streamedSince != 0) {
      _accrued = _accrued.add(_streamInfo.totalIncoming.mul(block.timestamp.sub(_streamInfo.streamedSince)));
      _streamInfo.streamedSince = block.timestamp;
    }
    balance[_account] = balance[_account].add(_accrued).sub(_amount, "ERC20: Burn amount exceeds balance");
    totalSupply = totalSupply.sub(_amount);
    emit Transfer(_account, address(0), _amount);
  }

  /* Getters */

  /** @dev Calculates how much UBI an address has available for withdrawal.
  *  @param _account The submission ID.
  *  @return accrued The available UBI for withdrawal.
  */
  function getAccruedValue(address _account) public view returns (uint256 accrued) {
    uint256 _accrued = 0;
    StreamInfo storage _streamInfo = streamInfo[_account];
    if (accruedSince[_account] != 0 && proofOfHumanity.isRegistered(_account)) {
      _accrued = accruedPerSecond.sub(_streamInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[_account]));
    }
    if (_streamInfo.streamedSince != 0) {
      _accrued = _accrued.add(_streamInfo.totalIncoming.mul(block.timestamp.sub(_streamInfo.streamedSince)));
    }
    return _accrued;
  }

  /**
  * @dev Calculates the current user accrued balance.
  * @param _human The submission ID.
  * @return The current balance including accrued Universal Basic Income of the user.
  **/
  function balanceOf(address _human) public view returns (uint256) {
    return (balance[_human] + getAccruedValue(_human));
  }

  /* Stream Functions */

/* Stream Events */
  /**
  * @dev Emitted when the `_src` creates new stream for `_dst`
  * `_src` is address(0) for Primary stream
  * `_drip` are UBI units moved into`_dst` stream.
  */
  event NewStream(address indexed _src, address indexed _dst, uint256 _drip);

  /**
  * @dev Emitted when the `_src` ~ `_dst` is stopped
  * `_src` is address(0) for Primary stream
  * `_drip` are UBI units moved out of `_dst` stream.
  */
  event EndStream(address indexed _src, address indexed _dst);

  /**
  * @dev Emitted when the `_src`'s PoH is revoked `_dst`.
  * `_src` is address(0) for Primary stream
  * `_drip` UBI units per second revoked from `_dst` stream.
  */
  event Revoked(address indexed _src, address indexed _dst);

  /** @dev Start secondary UBI stream to any address
   * @param _dst destination address
   * @param _dripPercent percentage of UBI to stream.
   */
  function startStream(address _dst, uint256 _dripPercent) external {
    StreamInfo storage senderInfo = streamInfo[msg.sender];
    require(_dst != address(0), "Zero address for destination.");
    require(senderInfo.outgoingRecipients.length < 5, "Max 5 outgoing streams");
    require(accruedSince[msg.sender] != 0, "Start accruing before streaming out.");
    uint256 _drip = accruedPerSecond.mul(_dripPercent).div(100);
    uint256 totalOutgoing = _drip.add(senderInfo.totalOutgoing);
    require(totalOutgoing <= accruedPerSecond, "Can't stream more than 100%.");
    for (uint i = 0; i < senderInfo.outgoingRecipients.length; i++) require(senderInfo.outgoingRecipients[i] != _dst, "Stream already active.");
    require(proofOfHumanity.isRegistered(msg.sender), "Not registered in PoH.");
    StreamInfo storage dstInfo = streamInfo[_dst];
    uint256 dstAccrued;
    if (dstInfo.streamedSince != 0) {
      dstAccrued = dstInfo.totalIncoming.mul(block.timestamp.sub(dstInfo.streamedSince));
      balance[_dst] = balance[_dst].add(dstAccrued); // settle dst balance
    }
    dstInfo.streamedSince = block.timestamp; // update dst timer
    uint256 senderAccrued = accruedPerSecond.sub(senderInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[msg.sender]));
    balance[msg.sender] = balance[msg.sender].add(senderAccrued);
    accruedSince[msg.sender] = block.timestamp; // update src timer
    streamInfo[msg.sender].outgoingRecipients.push(_dst);
    streamInfo[msg.sender].streams[_dst] = _drip;
    senderInfo.totalOutgoing = totalOutgoing; // add outgoing stream for src
    dstInfo.totalIncoming = dstInfo.totalIncoming.add(_drip); // add incoming stream for dst
    emit NewStream(msg.sender, _dst, _drip);
  }

  /** @dev Stop secondary UBI stream
   * @param _dst destination address to stop
   */
  function stopStream(address _dst) external {
    StreamInfo storage senderInfo = streamInfo[msg.sender];
    require(proofOfHumanity.isRegistered(msg.sender), "Your address is not registered in Proof Of Humanity.");
    require(_dst != address(0), "Zero address as stream destination.");
    uint256 dstIndex = 5;
    for (uint256 i = 0; i < senderInfo.outgoingRecipients.length; i++) {
      if (senderInfo.outgoingRecipients[i] == _dst) {
        dstIndex = i;
        break;
      }
    }
    require(dstIndex != 5, "Stream not active.");
    StreamInfo storage dstInfo = streamInfo[_dst];
    uint256 dstAccrued = dstInfo.totalIncoming.mul(block.timestamp.sub(dstInfo.streamedSince));
    balance[_dst] = balance[_dst].add(dstAccrued); // settle dst balance
    dstInfo.streamedSince = block.timestamp; // update dst timer
    uint256 senderAccrued = accruedPerSecond.sub(senderInfo.totalOutgoing).mul(block.timestamp.sub(accruedSince[msg.sender]));
    balance[msg.sender] = balance[msg.sender].add(senderAccrued);
    accruedSince[msg.sender] = block.timestamp;
    uint256 _drip = senderInfo.streams[_dst];
    if ((senderInfo.outgoingRecipients.length > 1) && (dstIndex + 1 < senderInfo.outgoingRecipients.length)){
      uint256 lastIndex = senderInfo.outgoingRecipients.length - 1;
      (senderInfo.outgoingRecipients[dstIndex], senderInfo.outgoingRecipients[lastIndex]) = (senderInfo.outgoingRecipients[lastIndex], senderInfo.outgoingRecipients[dstIndex]);
    }
    senderInfo.streams[_dst] = 0;
    senderInfo.outgoingRecipients.pop();
    senderInfo.totalOutgoing = senderInfo.totalOutgoing.sub(_drip); // subtract outgoing stream for src
    dstInfo.totalIncoming = dstInfo.totalIncoming.sub(_drip); // subtract incoming stream for dst
    if (dstInfo.totalIncoming == 0) {
      dstInfo.streamedSince = 0;
    }
    emit EndStream(msg.sender, _dst); // close stream
  }
}
