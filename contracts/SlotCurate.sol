/**
 * @authors: @greenlucid
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.4;
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

/*
    things to think about

    remove this comment when you skim through all the previous comments
    and write "bugs" that really are deliberate decisions to optimize gas
    and the workarounds there are around them.

    put the most used functions (add, remove item) as first functions because that
    makes it cheaper
    actually:
    it's not based on order, but on the hash of the function string definition.
    the function hashes are ordered in some way
    functions that come last cost extra 22 gas per every function that is checked before
    there are 32 public funcs, so the one that comes last will cost 31 * 22 = 682 extra gas.
    so the main function "addItem", assuming is roughly in the middle, costs 341 extra gas.
    ~0.2 USD at current price
    if you make it the first function (by naming it addItem4, for example), you save it.
    this optimization is WIP because gas savings
    have been lower than expected (~100 gas). TODO look into it


    consider should we have remover / challenger submit "reason", somehow? as another ipfs.
    that'd make those events ~2k more expensive
    but should make the challenging / removing process more healthy.
    if the removal / challenging reason is proved wrong, then even if the item somehow
    doesn't belong there, it is allowed.
*/

contract SlotCurate is IArbitrable, IEvidence {
  uint256 internal constant AMOUNT_BITSHIFT = 32; // this could make submitter lose up to 4 gwei
  uint256 internal constant RULING_OPTIONS = 2;
  uint256 internal constant DIVIDER = 1_000_000;

  enum ProcessType {
    Add,
    Removal,
    Edit
  }

  enum Party {
    Requester,
    Challenger
  }

  enum DisputeState {
    Free,
    Used
  }

  // settings cannot be mutated once created, otherwise pending processes could get attacked.
  struct Settings {
    uint80 requesterStake;
    uint40 requestPeriod;
    uint64 multiplier; // divide by DIVIDER for float.
    uint72 freeSpace;
    bytes arbitratorExtraData; // since you're deploying with a known arbitrator
    // you can hardcode the size of the arbitratorExtraData and save 1 storage slot
    // like, bytes32[2] arbitratorExtraData
    // just transform it when needed.
    // should be cheaper to interact with since you don't have to storage read the length
    // (because "bytes" stores length too)
    // even, if arb doesn't need a lot of data
    // you can just store it in the free space.
    // e.g. KlerosLiquid uses like 32 bits of data max.
  }

  struct List {
    uint48 settingsId;
    address governor; // governors can change governor of the list, and change settingsId
    uint48 freeSpace;
  }

  struct Slot {
    uint8 slotdata; // holds "used", "processType" and "disputed", compressed in the same variable.
    uint48 settingsId; // settings spam attack is highly unlikely (1M years of full 15M gas blocks)
    uint40 requestTime; // overflow in 37k years
    address requester;
  }

  // all bounded data related to the DisputeSlot. unbounded data such as contributions is handled out
  // takes 3 slots
  struct DisputeSlot {
    uint256 arbitratorDisputeId; // required
    uint64 slotId; // flexible
    address challenger; // store it here instead of contributions[dispute][0]
    DisputeState state;
    uint8 currentRound;
    bool pendingInitialWithdraw;
    uint8 freeSpace;
    uint64 nContributions;
    uint64 pendingWithdraws;
    uint40 appealDeadline; // to derive
    uint88 freeSpace2;
  }

  struct Contribution {
    uint8 round; // could be bigger. but because exp cost, shouldn't be needed.
    // if you have a bool "firstOfRound" instead.
    // you could save 1 byte
    // but would make withdrawOneContribution O(n) because rewards are distributed
    // round wise
    uint8 contribdata; // compressed form of bool withdrawn, Party party.
    uint80 amount; // to be raised 32 bits.
    address contributor; // could be compressed to 64 bits, but there's no point.
  }

  struct RoundContributions {
    uint80[2] partyTotal; // partyTotal[Party]
    uint80 appealCost;
    uint16 filler; // to make sure the storage slot never goes back to zero, set it to 1 on discovery.
  }

  struct StoredRuling {
    uint240 ruling;
    bool ruled;
    bool executed;
  }

  // EVENTS //

  event ListCreated(uint48 _settingsId, address _governor, string _ipfsUri);
  event ListUpdated(uint64 _listIndex, uint48 _settingsId, address _governor, string _ipfsUri);
  // _requesterStake, _requestPeriod,
  event SettingsCreated(uint80 _requesterStake, uint40 _requestPeriod, bytes _arbitratorExtraData);
  // why emit settingsId in the request events?
  // it's cheaper to trust the settingsId in the contract, than read it from the list and verifying
  // the subgraph can check the list at that time and ignore requests with invalid settings.
  
  // every byte costs 8 gas so 80 gas saving by publishing uint176
  event ItemAddRequest(uint176 _addRequestData, string _ipfsUri);
  event ItemRemovalRequest(uint240 _removalRequestData);
  event ItemEditRequest(uint240 _editRequestData, string _ipfsUri);
  // you don't need different events for accept / reject because subgraph remembers the progress per slot.
  event RequestAccepted(uint64 _slotIndex);
  event RequestRejected(uint64 _slotIndex);

  // how to tell if DisputeSlot is now used? You need to emit an event here
  // because the Challenge event in Arbitrator only knows about external disputeId
  // these events allow the subgraph to know the status of DisputeSlots
  event RequestChallenged(uint64 _slotIndex, uint64 _disputeSlot);
  event FreedDisputeSlot(uint64 _disputeSlot);


  // CONTRACT STORAGE //


  IArbitrator immutable internal arbitrator;
  uint64 internal listCount;
  uint48 internal settingsCount; // to prevent from assigning invalid settings to lists.

  mapping(uint64 => Slot) internal slots;
  mapping(uint64 => DisputeSlot) internal disputes;
  mapping(uint64 => List) internal lists;
  // a spam attack would take ~1M years of filled mainnet blocks to deplete settings id space.
  mapping(uint48 => Settings) internal settingsMap;
  mapping(uint64 => mapping(uint64 => Contribution)) internal contributions; // contributions[disputeSlot][n]
  // totalContributions[disputeSlot][round][Party]
  mapping(uint64 => mapping(uint8 => RoundContributions)) internal roundContributionsMap;
  mapping(uint256 => StoredRuling) internal storedRulings; // storedRulings[disputeId]

  constructor(address _arbitrator) {
    arbitrator = IArbitrator(_arbitrator);
  }

  // PUBLIC FUNCTIONS

  function createList(
    uint48 _settingsId,
    address _governor,
    string calldata _ipfsUri
  ) external {
    require(_settingsId < settingsCount, "Settings must exist");
    // requiring that listCount != type(uint64).max is not needed. makes it ~1k more expensive
    // and listCount exceeding that number is just not gonna happen. ~32B years of filling blocks.
    List storage list = lists[listCount++];
    list.governor = _governor;
    list.settingsId = _settingsId;
    emit ListCreated(_settingsId, _governor, _ipfsUri);
  }

  function updateList(
    uint64 _listIndex,
    uint48 _settingsId,
    address _newGovernor,
    string calldata _ipfsUri
  ) external {
    List storage list = lists[_listIndex];
    require(msg.sender == list.governor, "You need to be the governor");
    list.governor = _newGovernor;
    list.settingsId = _settingsId;
    emit ListUpdated(_listIndex, _settingsId, _newGovernor, _ipfsUri);
  }

  function createSettings(
    uint80 _requesterStake,
    uint40 _requestPeriod,
    uint64 _multiplier,
    bytes calldata _arbitratorExtraData,
    string calldata _addMetaEvidence,
    string calldata _removeMetaEvidence,
    string calldata _updateMetaEvidence
  ) external {
    // require is not used. there can be up to 281T.
    // that's 1M years of full 15M gas blocks every 13s.
    // skipping it makes this cheaper. overflow is not gonna happen.
    // a rollup in which this was a risk might be possible, but then just remake the contract.
    // require(settingsCount != type(uint48).max, "Max settings reached");
    Settings storage settings = settingsMap[settingsCount++];
    settings.requesterStake = _requesterStake;
    settings.requestPeriod = _requestPeriod;
    settings.multiplier = _multiplier;
    settings.arbitratorExtraData = _arbitratorExtraData;

    emit MetaEvidence(3 * settingsCount, _addMetaEvidence);
    emit MetaEvidence(3 * settingsCount + 1, _removeMetaEvidence);
    emit MetaEvidence(3 * settingsCount + 1, _updateMetaEvidence);
    emit SettingsCreated(_requesterStake, _requestPeriod, _arbitratorExtraData);
  }

  // no refunds for overpaying. consider it burned. refunds are bloat.

  // in the contract, listIndex and settingsId are trusted.
  // but in the subgraph, if listIndex doesnt exist or settings are not really the ones on list
  // then item will be ignored or marked as invalid.

  // fix for all requests
  function addItem(
    uint64 _listIndex,
    uint48 _settingsId,
    uint64 _idSlot,
    string calldata _ipfsUri
  ) external payable {
    Slot storage slot = slots[_idSlot];
    // If free, it is of form 0xxx0000, so it's smaller than 128
    require(slot.slotdata < 128, "Slot must not be in use");
    require(msg.value >= decompressAmount(settingsMap[_settingsId].requesterStake), "Not enough to cover stake");
    // used: true, disputed: false, processType: Add
    // paramsToSlotdata(true, false, ProcessType.Add) = 128
    slot.slotdata = 128;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // format of uint176 addRequestData: [List: L, Settings: S, idSlot: I]
    // LLLLLLLLSSSSSSIIIIIIII
    // move list 14, move settings 8, add idSlot.
    emit ItemAddRequest(((_listIndex << 14) + (_settingsId << 8) + _idSlot), _ipfsUri);
  }

  // frontrunning protection
  function addItemInFirstFreeSlot(
    uint64 _listIndex,
    uint48 _settingsId,
    uint64 _fromSlot,
    string calldata _ipfsUri
  ) external payable {
    uint64 workSlot = firstFreeSlot(_fromSlot);
    require(msg.value >= decompressAmount(settingsMap[_settingsId].requesterStake), "Not enough to cover stake");
    Slot storage slot = slots[workSlot];
    // used: true, disputed: false, processType: Add
    // paramsToSlotdata(true, false, ProcessType.Add) = 128
    slot.slotdata = 128;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // format of uint176 addRequestData: [List: L, Settings: S, idSlot: I]
    // LLLLLLLLSSSSSSIIIIIIII
    // move list 14, move settings 8, add idSlot.
    emit ItemAddRequest(((_listIndex << 14) + (_settingsId << 8) + workSlot), _ipfsUri);
  }

  function removeItem(
    uint64 _workSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId
  ) external payable {
    Slot storage slot = slots[_workSlot];
    // If free, it is of form 0xxx0000, so it's smaller than 128
    require(slot.slotdata < 128, "Slot must not be in use");
    require(msg.value >= decompressAmount(settingsMap[_settingsId].requesterStake), "Not enough to cover stake");
    // used: true, disputed: false, processType: Removal
    // paramsToSlotdata(true, false, ProcessType.Removal) = 144
    slot.slotdata = 144;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // format of uint240 removeRequestData: [WorkSlot: W, Settings: S, List: L, idItem: I]
    // WWWWWWWWSSSSSSLLLLLLLLIIIIIIII
    // move list 14, move settings 8, add idSlot.
    emit ItemRemovalRequest((_workSlot << 22) + (_settingsId << 16) + (_listId << 8) + _itemId);
  }

  function removeItemInFirstFreeSlot(
    uint64 _fromSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId
  ) external payable {
    uint64 workSlot = firstFreeSlot(_fromSlot);
    Slot storage slot = slots[workSlot];
    require(msg.value >= decompressAmount(settingsMap[_settingsId].requesterStake), "Not enough to cover stake");
    // used: true, disputed: false, processType: Removal
    // paramsToSlotdata(true, false, ProcessType.Removal) = 144
    slot.slotdata = 144;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // format of uint240 removeRequestData: [WorkSlot: W, Settings: S, List: L, idItem: I]
    // WWWWWWWWSSSSSSLLLLLLLLIIIIIIII
    // move list 14, move settings 8, add idSlot.
    emit ItemRemovalRequest((workSlot << 22) + (_settingsId << 16) + (_listId << 8) + _itemId);
  }

  function editItem(
    uint64 _workSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId,
    string calldata _ipfsUri
  ) external payable {
    Slot storage slot = slots[_workSlot];
    // If free, it is of form 0xxx0000, so it's smaller than 128
    require(slot.slotdata < 128, "Slot must not be in use");
    require(msg.value >= decompressAmount(settingsMap[_settingsId].requesterStake), "Not enough to cover stake");
    // used: true, disputed: false, processType: Edit
    // paramsToSlotdata(true, false, ProcessType.Edit) = 160
    slot.slotdata = 160;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // format of uint240 editRequestData: [WorkSlot: W, Settings: S, List: L, idItem: I]
    // WWWWWWWWSSSSSSLLLLLLLLIIIIIIII
    // move list 14, move settings 8, add idSlot.
    emit ItemEditRequest(((_workSlot << 22) + (_settingsId << 16) + (_listId << 8) + _itemId), _ipfsUri);
  }

  function editItemInFirstFreeSlot(
    uint64 _fromSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId,
    string calldata _ipfsUri
  ) external payable {
    uint64 workSlot = firstFreeSlot(_fromSlot);
    Slot storage slot = slots[workSlot];
    require(msg.value >= decompressAmount(settingsMap[_settingsId].requesterStake), "Not enough to cover stake");
    // used: true, disputed: false, processType: Edit
    // paramsToSlotdata(true, false, ProcessType.Edit) = 160
    slot.slotdata = 160;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // format of uint240 editRequestData: [WorkSlot: W, Settings: S, List: L, idItem: I]
    // WWWWWWWWSSSSSSLLLLLLLLIIIIIIII
    // move list 14, move settings 8, add idSlot.
    emit ItemEditRequest(((workSlot << 22) + (_settingsId << 16) + (_listId << 8) + _itemId), _ipfsUri);
  }

  function executeRequest(uint64 _slotIndex) external {
    Slot storage slot = slots[_slotIndex];
    Settings storage settings = settingsMap[slot.settingsId];
    require(slotIsExecutable(slot, settings.requestPeriod), "Slot cannot be executed");
    payable(slot.requester).transfer(settings.requesterStake);
    emit RequestAccepted(_slotIndex);
    // used to false, others don't matter.
    slot.slotdata = paramsToSlotdata(false, false, ProcessType.Add);
  }

  function challengeRequest(uint64 _slotIndex, uint64 _disputeSlot) public payable {
    Slot storage slot = slots[_slotIndex];
    Settings storage settings = settingsMap[slot.settingsId];
    require(slotCanBeChallenged(slot, settings.requestPeriod), "Slot cannot be challenged");

    DisputeSlot storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Free, "That dispute slot is being used");

    // dont require enough to cover arbitration fees
    // arbitrator will already take care of it
    // challenger pays arbitration fees + gas costs fully

    uint256 arbitratorDisputeId = arbitrator.createDispute{value: msg.value}(RULING_OPTIONS, settings.arbitratorExtraData);

    (, , ProcessType processType) = slotdataToParams(slot.slotdata);
    uint8 newSlotdata = paramsToSlotdata(true, true, processType);

    slot.slotdata = newSlotdata;
    dispute.arbitratorDisputeId = arbitratorDisputeId;
    dispute.slotId = _slotIndex;
    dispute.challenger = msg.sender;
    dispute.state = DisputeState.Used;
    dispute.currentRound = 0;
    dispute.pendingInitialWithdraw = true;
    dispute.nContributions = 0;
    dispute.pendingWithdraws = 0;
    dispute.appealDeadline = 0;
    dispute.freeSpace2 = 1; // to make sure slot never goes to zero.

    // initialize roundContributions of round: 1
    // will be 5k in reused. but 20k in new.
    RoundContributions storage roundContributions = roundContributionsMap[_disputeSlot][1];
    roundContributions.filler = 1;
    roundContributions.appealCost = 0;
    roundContributions.partyTotal[0] = 0;
    roundContributions.partyTotal[1] = 0;

    emit RequestChallenged(_slotIndex, _disputeSlot);
  }

  function challengeRequestInFirstFreeSlot(uint64 _slotIndex, uint64 _fromSlot) public payable {
    uint64 disputeWorkSlot = firstFreeDisputeSlot(_fromSlot);
    challengeRequest(_slotIndex, disputeWorkSlot);
  }

  function contribute(uint64 _disputeSlot, Party _party) public payable {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Used, "DisputeSlot has to be used");

    _verifyUnderAppealDeadline(dispute);

    uint8 nextRound = dispute.currentRound + 1;
    uint8 contribdata = paramsToContribdata(true, _party);
    dispute.nContributions++;
    dispute.pendingWithdraws++;
    // compress amount, possibly losing up to 4 gwei. they will be burnt.
    uint80 amount = compressAmount(msg.value);
    roundContributionsMap[_disputeSlot][nextRound].partyTotal[uint256(_party)] += amount;
    contributions[_disputeSlot][dispute.nContributions++] = Contribution({round: nextRound, contribdata: contribdata, contributor: msg.sender, amount: amount});
  }

  function startNextRound(uint64 _disputeSlot) public {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    uint8 nextRound = dispute.currentRound + 1; // to save gas with less storage reads
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    require(dispute.state == DisputeState.Used, "DisputeSlot has to be Used");

    _verifyUnderAppealDeadline(dispute);

    uint256 appealCost = arbitrator.appealCost(dispute.arbitratorDisputeId, settings.arbitratorExtraData);
    uint256 totalAmountNeeded = (appealCost * settings.multiplier) / DIVIDER;

    // make sure you have the required amount
    uint256 currentAmount = decompressAmount(roundContributionsMap[_disputeSlot][nextRound].partyTotal[0] + roundContributionsMap[_disputeSlot][nextRound].partyTotal[1]);
    require(currentAmount >= totalAmountNeeded, "Not enough to fund round");

    // got enough, it's legit to do so. I can appeal, lets appeal
    arbitrator.appeal{value: appealCost}(dispute.arbitratorDisputeId, settings.arbitratorExtraData);

    // remember the appeal cost, for sharing the spoils later
    roundContributionsMap[_disputeSlot][nextRound].appealCost = compressAmount(appealCost);

    dispute.currentRound++;

    // set the roundContributions of the upcoming round to zero.
    RoundContributions storage roundContributions = roundContributionsMap[_disputeSlot][nextRound + 1];
    roundContributions.appealCost = 0;
    roundContributions.partyTotal[0] = 0;
    roundContributions.partyTotal[1] = 0;
    roundContributions.filler = 1; // to avoid getting whole storage slot to 0.

    // you may to emit an event for this. but there's no need
    // arbitrator will surely do it for you
  }

  function executeRuling(uint64 _disputeSlot) public {
    //1. get disputeId from disputeSlot.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    // 2. make sure that disputeSlot has an ongoing dispute
    require(dispute.state == DisputeState.Used, "Can only be executed if Used");
    // 3. access storedRulings[disputeId]. make sure it's ruled.
    StoredRuling storage storedRuling = storedRulings[dispute.arbitratorDisputeId];
    require(storedRuling.ruled, "Wasn't ruled by the arbitrator");
    require(!storedRuling.executed, "Has already been executed");
    // 4. apply ruling. what to do when refuse to arbitrate? dunno. maybe... just
    // default to requester, in that case.
    // 0 refuse, 1 requester, 2 challenger.
    if (storedRuling.ruling == 1 || storedRuling.ruling == 0) {
      // requester won.
      emit RequestAccepted(dispute.slotId);
    } else {
      // challenger won.
      emit RequestRejected(dispute.slotId);
    }
    // 5. slot is now Free.. other slotdata doesn't matter.
    slot.slotdata = paramsToSlotdata(false, false, ProcessType.Add);
    storedRuling.executed = true; // to avoid someone from calling this again.
    // dispute is intentionally left alone. wont be freed until withdrawn contribs.
  }

  function rule(uint256 _disputeId, uint256 _ruling) external override {
    // no need to check if already ruled, arbitrator is trusted.
    require(msg.sender == address(arbitrator), "Only arbitrator can rule");
    storedRulings[_disputeId] = StoredRuling({ruling: uint240(_ruling), ruled: true, executed: false});
    emit Ruling(arbitrator, _disputeId, _ruling);
  }

  function withdrawOneContribution(uint64 _disputeSlot, uint64 _contributionSlot) public {
    // check if dispute is used.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    // withdrawAllRewards does not set the flag on "withdrawn" individually.
    // that's why you check for dispute as well.
    require(dispute.state == DisputeState.Used, "DisputeSlot must be in use");
    require(dispute.nContributions > _contributionSlot, "DisputeSlot lacks that contrib");
    // to check if dispute is really over.
    StoredRuling storage storedRuling = storedRulings[dispute.arbitratorDisputeId];
    require(storedRuling.ruled && storedRuling.executed, "Must be ruled and executed");

    Contribution storage contribution = contributions[_disputeSlot][_contributionSlot];
    (bool pendingWithdrawal, Party party) = contribdataToParams(contribution.contribdata);

    require(pendingWithdrawal, "Contribution withdrawn already");

    // okay, all checked. let's get the contribution.

    RoundContributions memory roundContributions = roundContributionsMap[_disputeSlot][contribution.round];

    if (roundContributions.appealCost != 0) {
      // then this is a contribution from an appealed round.
      // only winner party can withdraw.
      require(party == whichPartyWon(storedRuling.ruling), "That side lost the dispute");

      _withdrawSingleReward(contribution, roundContributions, party);
    } else {
      // this is a contrib from a round that didnt get appealed.
      // just refund the same amount
      uint256 refund = decompressAmount(contribution.amount);
      payable(contribution.contributor).transfer(refund);
    }

    if (dispute.pendingWithdraws == 1 && !dispute.pendingInitialWithdraw) {
      // this was last contrib remaining
      // no need to decrement pendingWithdraws if last. save gas.
      dispute.state = DisputeState.Free;
      emit FreedDisputeSlot(_disputeSlot);
    } else {
      dispute.pendingWithdraws--;
    }
  }

  function withdrawRoundZero(uint64 _disputeSlot) public {
    // "round zero" refers to the initial requester stake
    // it's not stored like the other contributions.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];

    require(dispute.state == DisputeState.Used, "DisputeSlot must be in use");
    // to check if dispute is really over.
    StoredRuling storage storedRuling = storedRulings[dispute.arbitratorDisputeId];
    require(storedRuling.ruled && storedRuling.executed, "Must be ruled and executed");
    require(dispute.pendingInitialWithdraw, "Round zero was already withdrawn");

    // withdraw it. this can be put onto its own private func.

    Party party = whichPartyWon(storedRuling.ruling);
    _withdrawRoundZero(dispute, settings, slot, party);

    if (dispute.pendingWithdraws == 0) {
      dispute.state = DisputeState.Free;
      emit FreedDisputeSlot(_disputeSlot);
    } else {
      dispute.pendingInitialWithdraw = false;
    }
  }

  function withdrawAllContributions(uint64 _disputeSlot) public {
    // this func is a "public good". it uses less gas overall to withdraw all
    // contribs. because you only need to change 1 single flag.
    // it also frees the dispute slot.
    // if frequent users set up a multisig, or some way to call it,
    // it would be cheaper in the long run.

    // check if dispute is used.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    // withdrawAllRewards does not set the flag on "withdrawn" individually.
    // that's why you check for dispute as well.
    require(dispute.state == DisputeState.Used, "DisputeSlot must be in use");
    StoredRuling storage storedRuling = storedRulings[dispute.arbitratorDisputeId];
    require(storedRuling.ruled && storedRuling.executed, "Must be ruled and executed");
    Party winningParty = whichPartyWon(storedRuling.ruling);
    uint8 pendingAndWinnerContribdata = 128 + 64 * uint8(winningParty);
    // this is a separate func to make it more efficient.
    // there are three contribs that are handled differently:
    // 1. the round zero
    if (dispute.pendingInitialWithdraw) {
      _withdrawRoundZero(dispute, settings, slot, winningParty);
    }
    // 2. then, the contribs of...
    uint64 contribSlot = 0;
    uint8 currentRound = 1;
    RoundContributions memory roundContributions = roundContributionsMap[_disputeSlot][currentRound];
    // 2.1. the fully funded and appealed rounds
    // withdraw to pending winners
    while (contribSlot < dispute.nContributions) {
      Contribution memory contribution = contributions[_disputeSlot][contribSlot];
      if (contribution.round != currentRound) {
        roundContributions = roundContributionsMap[_disputeSlot][contribution.round];
        currentRound = contribution.round;
      }
      if (currentRound > dispute.currentRound) break;

      if (contribution.contribdata == pendingAndWinnerContribdata) {
        _withdrawSingleReward(contribution, roundContributions, winningParty);
      }
      contribSlot++;
    }

    // 2.2. the last, unnappealed round
    while (contribSlot < dispute.nContributions) {
      // refund every transaction
      Contribution memory contribution = contributions[_disputeSlot][contribSlot];
      _refundContribution(contribution);
      contribSlot++;
    }
    // afterwards, set the dispute slot to Free.
    dispute.state = DisputeState.Free;
  }

  // PRIVATE FUNCTIONS

  // can mutate storage. reverts if not under appealDeadline
  function _verifyUnderAppealDeadline(DisputeSlot storage _dispute) private {
    if (block.timestamp >= _dispute.appealDeadline) {
      // you're over it. get updated appealPeriod
      (, uint256 end) = arbitrator.appealPeriod(_dispute.arbitratorDisputeId);
      require(block.timestamp < end, "Over submision period");
      _dispute.appealDeadline = uint40(end);
    }
  }

  function _withdrawRoundZero(
    DisputeSlot storage _dispute,
    Settings storage _settings,
    Slot storage _slot,
    Party _party
  ) private {
    // this method is already told who won.
    uint256 amount = decompressAmount(_settings.requesterStake);
    if (_party == Party.Requester) {
      payable(_slot.requester).transfer(amount);
    } else if (_party == Party.Challenger) {
      payable(_dispute.challenger).transfer(amount);
    }
  }

  function _withdrawSingleReward(
    Contribution memory _contribution,
    RoundContributions memory _roundContributions,
    Party _winningParty
  ) private {
    uint256 spoils = decompressAmount(_roundContributions.partyTotal[0] + _roundContributions.partyTotal[1] - _roundContributions.appealCost);
    uint256 share = (spoils * uint256(_contribution.amount)) / uint256(_roundContributions.partyTotal[uint256(_winningParty)]);
    payable(_contribution.contributor).transfer(share);
  }

  function _refundContribution(Contribution memory _contribution) private {
    uint256 refund = decompressAmount(_contribution.amount);
    payable(_contribution.contributor).transfer(refund);
  }

  function submitEvidence(uint64 _disputeSlot, string calldata _evidenceURI) external {
    DisputeSlot storage dispute = disputes[_disputeSlot];

    emit Evidence(arbitrator, dispute.arbitratorDisputeId, msg.sender, _evidenceURI);
  }

  // VIEW FUNCTIONS

  // relying on this by itself could result on users colliding on same slot
  // user which is late will have the transaction cancelled, but gas wasted and unhappy ux
  // could be used to make an "emergency slot", in case your slot submission was in an used slot.
  // will get the first Virgin, or Created slot.
  function firstFreeSlot(uint64 _startPoint) public view returns (uint64) {
    uint64 i = _startPoint;
    // this is used == true, because if used, slotdata is of shape 1xxx0000, so it's larger than 127
    while (slots[i].slotdata > 127) {
      i++;
    }
    return i;
  }

  function firstFreeDisputeSlot(uint64 _startPoint) public view returns (uint64) {
    uint64 i = _startPoint;
    while (disputes[i].state == DisputeState.Used) {
      i++;
    }
    return i;
  }

  function slotIsExecutable(Slot memory _slot, uint40 requestPeriod) public view returns (bool) {
    (bool used, bool disputed, ) = slotdataToParams(_slot.slotdata);
    return used && (block.timestamp > _slot.requestTime + requestPeriod) && !disputed;
  }

  function slotCanBeChallenged(Slot memory _slot, uint40 requestPeriod) public view returns (bool) {
    (bool used, bool disputed, ) = slotdataToParams(_slot.slotdata);
    return used && !(block.timestamp > _slot.requestTime + requestPeriod) && !disputed;
  }

  function challengeFee(uint64 _slotIndex) public view returns (uint256 arbitrationFee) {
    Slot storage slot = slots[_slotIndex];
    Settings storage settings = settingsMap[slot.settingsId];

    arbitrationFee = arbitrator.arbitrationCost(settings.arbitratorExtraData);
  }

  function paramsToSlotdata(
    bool _used,
    bool _disputed, // you store disputed to stop someone from calling executeRequest
    ProcessType _processType
  ) public pure returns (uint8) {
    uint8 usedAddend;
    if (_used) usedAddend = 128;
    uint8 disputedAddend;
    if (_disputed) disputedAddend = 64;
    uint8 processTypeAddend;
    if (_processType == ProcessType.Removal) processTypeAddend = 16;
    if (_processType == ProcessType.Edit) processTypeAddend = 32;
    uint8 slotdata = usedAddend + processTypeAddend + disputedAddend;
    return slotdata;
  }

  function slotdataToParams(uint8 _slotdata)
    public
    pure
    returns (
      bool,
      bool,
      ProcessType
    )
  {
    uint8 usedAddend = _slotdata & 128;
    bool used = usedAddend != 0;
    uint8 disputedAddend = _slotdata & 64;
    bool disputed = disputedAddend != 0;

    uint8 processTypeAddend = _slotdata & 48;
    ProcessType processType = ProcessType(processTypeAddend >> 4);

    return (used, disputed, processType);
  }

  function paramsToContribdata(bool _pendingWithdrawal, Party _party) public pure returns (uint8) {
    uint8 pendingWithdrawalAddend;
    if (_pendingWithdrawal) pendingWithdrawalAddend = 128;
    uint8 partyAddend;
    if (_party == Party.Challenger) partyAddend = 64;

    uint8 contribdata = pendingWithdrawalAddend + partyAddend;
    return contribdata;
  }

  function contribdataToParams(uint8 _contribdata) public pure returns (bool, Party) {
    uint8 pendingWithdrawalAddend = _contribdata & 128;
    bool pendingWithdrawal = pendingWithdrawalAddend != 0;
    uint8 partyAddend = _contribdata & 64;
    Party party = Party(partyAddend >> 6);

    return (pendingWithdrawal, party);
  }

  // always compress / decompress rounding down.
  function compressAmount(uint256 _amount) public pure returns (uint80) {
    return (uint80(_amount >> AMOUNT_BITSHIFT));
  }

  function decompressAmount(uint80 _compressedAmount) public pure returns (uint256) {
    return (uint256(_compressedAmount) << AMOUNT_BITSHIFT);
  }

  function whichPartyWon(uint248 _ruling) public pure returns (Party) {
    if (_ruling == 0 || _ruling == 1) {
      return Party.Requester;
    } else {
      return Party.Challenger;
    }
  }
}
