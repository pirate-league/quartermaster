// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule } from "hats-module/HatsModule.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";

struct Orders {
  bool isOnboarding;
  uint256 until;
  uint256 shares;
}

/**
 * @title Quartermaster Shaman
 * @notice A Baal manager shaman that allows onboarding, offboarding, and other DAO member management
 * by the holder of the captain hat. The captain uses the quartermaster to give crew status to new members,
 * but there is a delay to avoid the captain gathering crew to avoid a mutiny.
 * @author @plor
 * @dev This contract inherits from the HatsModule contract, and is meant to be deployed as a clone from the
 * HatsModuleFactory.
 */
contract QuartermasterShaman is HatsModule {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error NotCaptain();

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event OnboardedBatch(address[] members, uint256[] sharesPending, uint256 delay);
  event OffboardedBatch(address[] members, uint256[] sharesPending, uint256 delay);
  event Quartered(address[] members, uint256[] shares, bool[] inbound);

  /*//////////////////////////////////////////////////////////////
                          PUBLIC CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /**
   * This contract is a clone with immutable args, which means that it is deployed with a set of
   * immutable storage variables (ie constants). Accessing these constants is cheaper than accessing
   * regular storage variables (such as those set on initialization of a typical EIP-1167 clone),
   * but requires a slightly different approach since they are read from calldata instead of storage.
   *
   * Below is a table of constants and their locations. The first three are inherited from HatsModule.
   *
   * For more, see here: https://github.com/Saw-mon-and-Natalie/clones-with-immutable-args
   *
   * --------------------------------------------------------------------+
   * CLONE IMMUTABLE "STORAGE"                                           |
   * --------------------------------------------------------------------|
   * Offset  | Constant            | Type    | Length | Source Contract  |
   * --------------------------------------------------------------------|
   * 0       | IMPLEMENTATION      | address | 20     | HatsModule       |
   * 20      | HATS                | address | 20     | HatsModule       |
   * 40      | hatId               | uint256 | 32     | HatsModule       |
   * 72      | BAAL                | address | 20     | this             |
   * 92      | CAPTAIN_HAT         | uint256 | 32     | this             |
   * 124     | STARTING_SHARES     | uint256 | 32     | this             |
   * --------------------------------------------------------------------+
   */

  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  function CAPTAIN_HAT() public pure returns (uint256) {
    return _getArgUint256(92);
  }

  function STARTING_SHARES() public pure returns (uint256) {
    return _getArgUint256(124);
  }

  /**
   * @dev These are not stored as immutable args in order to enable instances to be set as shamans in new Baal
   * deployments via `initializationActions`, which is not possible if these values determine an instance's address.
   * While this means that they are stored normally in contract state, we still treat them as constants since they
   * cannot be mutated after initialization.
   */
  IBaalToken public SHARES_TOKEN;

  /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  mapping(address => Orders) public orders;

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc HatsModule
  function _setUp(bytes calldata) internal override {
    SHARES_TOKEN = IBaalToken(BAAL().sharesToken());

    // no need to emit an event, as this value is emitted in the HatsModuleFactory_ModuleDeployed event
  }

  /*//////////////////////////////////////////////////////////////
                          SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

  function onboard(address[] calldata _members) external wearsCaptainHat(msg.sender) {
    uint256 length = _members.length;
    uint256 delay = _calculateDelay();
    uint256 startingShares = STARTING_SHARES(); // avoid repeated fn
    uint256[] memory amounts = new uint256[](length);
    address member;

    for (uint256 i; i < length;) {
      member = _members[i];
      if (orders[member].until == 0 && SHARES_TOKEN.balanceOf(member) == 0) {
        orders[member] = Orders(true, delay, startingShares);
        amounts[i] = startingShares; // else 0
      }

      unchecked {
        ++i;
      }
    }
    emit OnboardedBatch(_members, amounts, delay);
  }

  /**
   * @notice Offboards a batch of members from the DAO, if they are not wearing the member hat. Offboarded members
   * lose their voting power, but keep a record of their previous shares in the form of loot.
   * @param _members The addresses of the members to offboard.
   */
  function offboard(address[] calldata _members) external wearsCaptainHat(msg.sender) {
    uint256 length = _members.length;
    uint256 delay = _calculateDelay();
    uint256[] memory amounts = new uint256[](length);
    address member;
    uint256 shares;

    for (uint256 i; i < length;) {
      member = _members[i];
      shares = SHARES_TOKEN.balanceOf(member);
      if (orders[member].until == 0 && shares > 0) {
        orders[member] = Orders(false, delay, shares);
        amounts[i] = shares; // else 0
      }

      unchecked {
        ++i;
      }
    }

    emit OffboardedBatch(_members, amounts, delay);
  }

  /**
   * Executes orders from onboarding and offboarding, any address can only be one or the other
   * until the orders are executed.
   */
  function quarter(address[] calldata _members) external {
    uint256 length = _members.length;
    uint256[] memory amounts = new uint256[](length);
    bool[] memory inbound = new bool[](length);

    bool isOnboarding;
    address[] memory singleMember = new address[](1);
    uint256[] memory singleShares = new uint256[](1);

    for (uint256 i; i < length;) {
      address member = _members[i];
      if (orders[member].until != 0 && orders[member].until <= block.timestamp) {
        isOnboarding = inbound[i] = orders[member].isOnboarding;
        singleMember[0] = member;
        singleShares[0] = amounts[i] = orders[member].shares;
        delete orders[member];

        if (isOnboarding) {
          BAAL().mintShares(singleMember, singleShares);
        } else {
          BAAL().burnShares(singleMember, singleShares);
        }
      }

      unchecked {
        ++i;
      }
    }
    emit Quartered(_members, amounts, inbound);
  }

  /*//////////////////////////////////////////////////////////////
                          PRIVATE FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Adds votingPeriod x2 to the current time to allow for mutiny delay
   */
  function _calculateDelay() private view returns (uint256 delay) {
    return block.timestamp + (2 * BAAL().votingPeriod());
  }

  /*//////////////////////////////////////////////////////////////
                          MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Reverts if the caller is not wearing the member hat.
   */
  modifier wearsCaptainHat(address _user) {
    if (!HATS().isWearerOfHat(_user, CAPTAIN_HAT())) revert NotCaptain();
    _;
  }
}
