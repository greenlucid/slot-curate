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

/*
    things to think about

    put an option to manually call the function to calculate juror fees and store it locally
    instead of calling an expensive function over contracts every time
    this would get harder if we store arbitrator / arbextradata separately

    put the most used functions (add, remove item) as first functions because that
    makes it cheaper

    ideas for the future:
    not even store all data to verify the process on chain. you could let invalid process on chain
    just exist and finish, and ignore them.
    you could even not store the lists logic at all, make them just be another item submission, somehow.
    again, the terms will be stored off chain, so whoever doesn't play by the rules is just ignored
    and you let their process exist and do whatever.

    consider should we have remover / challenger submit "reason", somehow? as another ipfs.
    that'd make those events ~2k more expensive
    but should make the challenging / removing process more healthy.
    if the removal / challenging reason is proved wrong, then even if the item somehow
    doesn't belong there, it is allowed.
    that reduces the scope of arguments, evidence, etc.
*/

contract SlotCurate is IArbitrable {
  uint256 internal constant AMOUNT_BITSHIFT = 32; // this could make submitter lose up to 4 gwei

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
    Free, // you can take slot
    Ruling, // arbitrator is ruling...
    Funding // users can contribute to seed next round. could also mean "over" if timestamp.
  }

  // settings cannot be mutated once created
  struct Settings {
    // you don't need to store created
    uint256 requesterStake;
    uint256 challengerStake;
    uint40 requestPeriod;
    uint40 fundingPeriod;
    address arbitrator;
    uint16 freeSpace;
    //  store extraData?!?!
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

  // all bounded data related to the Dispute. unbounded data such as contributions is handled out
  // todo
  struct Dispute {
    // you could save 8 bits by just having "used" be nContributions == 0.
    // and setting nContributions to zero when contribs are cashed out, so dispute slot is available.
    // but there's no gas to save doing so (yet)
    uint256 arbitratorDisputeId; // required
    uint64 slotId; // flexible
    address challenger; // store it here instead of contributions[dispute][0]
    DisputeState state;
    uint8 currentRound;
    uint24 freeSpace;
    uint64 nContributions; // if 0, it means slot is unused.
    uint40 timestamp; // to derive
    uint152 freeSpace2;
  }

  struct Contribution {
    uint8 round; // could be bigger, there's enough space by shifting amount.
    Party party;
    uint80 amount; // to be raised 32 bits.
    address contributor; // could be compressed to 64 bits, but there's no point.
  }

  struct StoredRuling {
    uint256 ruling;
    bool ruled; // this bit costs 20k gas (ferit: bool is uint8 under the hood, don't forget.)
  }

  // EVENTS //

  event ListCreated(uint64 _listIndex, uint48 _settingsId, address _governor, string _ipfsUri);
  event ListUpdated(uint64 _listIndex, uint48 _settingsId, address _governor);
  event SettingsCreated(uint256 _requestPeriod, uint256 _requesterStake, uint256 _challengerStake);
  // why emit settingsId in the request events?
  // it's cheaper to trust the settingsId in the contract, than get it from the list and verifying X
  // which I don't remember... TODO recheck this. look into getting it from list without verifying.
  // this would entail again, verifying that list exists in the subgraph, or whatever.
  // the subgraph can check the list at that time and ignore requests with invalid thing.
  // so that the result of the dispute is meaningless for Curate................
  event ItemAddRequest(uint64 _listIndex, uint48 _settingsId, uint64 _slotIndex, string _ipfsUri);
  event ItemRemovalRequest(uint64 _workSlot, uint48 _settingsId, uint64 _idSlot, uint40 _idRequestTime);
  event ItemEditRequest(uint64 _workSlot, uint48 _settingsId, uint64 _idSlot, uint40 _idRequestTime);
  // you don't need different events for accept / reject because subgraph remembers the progress per slot.
  event RequestAccepted(uint64 _slotIndex);
  event RequestRejected(uint64 _slotIndex);

  // CONTRACT STORAGE //
  uint64 internal listCount;
  uint48 internal settingsCount; // to prevent from assigning invalid settings to lists.

  mapping(uint64 => Slot) internal slots;
  mapping(uint64 => Dispute) internal disputes;
  mapping(uint64 => List) internal lists;
  // a spam attack would take ~1M years of filled mainnet blocks to deplete settings id space.
  mapping(uint48 => Settings) internal settingsMap;
  mapping(uint256 => mapping(uint64 => Contribution)) internal contributions; // contributions[disputeSlot][n]
  mapping(address => mapping(uint256 => StoredRuling)) internal storedRulings; // storedRulings[arbitrator][disputeId]

  // PUBLIC FUNCTIONS

  // lists
  function createList(
    address _governor,
    uint48 _settingsId,
    string memory _ipfsUri
  ) public {
    require(_settingsId < settingsCount, "Settings must exist");
    List storage list = lists[listCount++];
    list.governor = _governor;
    list.settingsId = _settingsId;
    emit ListCreated(listCount - 1, _settingsId, _governor, _ipfsUri);
  }

  function updateList(
    uint64 _listIndex,
    uint48 _settingsId,
    address _newGovernor
  ) public {
    List storage list = lists[_listIndex];
    require(msg.sender == list.governor, "You need to be the governor");
    list.governor = _newGovernor;
    list.settingsId = _settingsId;
    emit ListUpdated(_listIndex, _settingsId, _newGovernor);
  }

  // settings
  // bit of a draft since I havent done the dispute side of things yet
  function createSettings(
    uint256 _requesterStake,
    uint256 _challengerStake,
    uint40 _requestPeriod,
    uint40 _fundingPeriod
  ) public {
    // put safeguard check? for checking if settingsCount is -1.
    require(settingsCount != 4294967295, "Max settings reached"); // there'd be 4.3B so please just reuse one
    Settings storage settings = settingsMap[settingsCount++];
    settings.requesterStake = _requesterStake;
    settings.challengerStake = _challengerStake;
    settings.requestPeriod = _requestPeriod;
    settings.fundingPeriod = _fundingPeriod;
    emit SettingsCreated(_requestPeriod, _requesterStake, _challengerStake);
  }

  // no refunds for overpaying. consider it burned. refunds are bloat.

  // you could add an "emergency" boolean option.
  // if on, and the chosen slotIndex is taken, it will look for the first unused slot and create there instead.
  // otherwise, the transaction fails. it's important to have it optional this since there could potentially be a lot of
  // taken slots.
  // but its important to have to option as safeguard in case frontrunners try to inhibit the protocol.
  // another way is making a separate wrapper public function for this, that calls the two main ones
  // (make one for add and another for remove. and another one for challenging (to get free dispute slot))

  // in the contract, listIndex and settingsId are trusted.
  // but in the subgraph, if listIndex doesnt exist or settings are not really the ones on list
  // then item will be ignored or marked as invalid.
  function addItem(
    uint64 _listIndex,
    uint48 _settingsId,
    uint64 _slotIndex,
    string memory _ipfsUri
  ) public payable {
    Slot storage slot = slots[_slotIndex];
    (bool used, , ) = slotdataToParams(slot.slotdata);
    require(used == false, "Slot must not be in use");
    Settings storage settings = settingsMap[_settingsId];
    require(msg.value >= settings.requesterStake, "Not enough to cover stake");
    // used: true, disputed: false, processType: Add 
    uint8 slotdata = paramsToSlotdata(true, false, ProcessType.Add);
    slot.slotdata = slotdata;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    // I don't remember why I removed the trusted settingsId emission before. review this.
    emit ItemAddRequest(_listIndex, _settingsId, _slotIndex, _ipfsUri);
  }

  // list is checked in subgraph. settings is trusted here.
  // if settings was not the one settings in subgraph at the time,
  // then subgraph will ignore the removal (so it has no effect when exec.)
  // could even be challenged as an ilegal request to extract the stake, if significant.
  function removeItem(
    uint64 _workSlot,
    uint48 _settingsId,
    uint64 _idSlot,
    uint40 _idRequestTime
  ) public payable {
    Slot storage slot = slots[_workSlot];
    (bool used, , ) = slotdataToParams(slot.slotdata);
    require(used == false, "Slot must not be in use");
    Settings storage settings = settingsMap[_settingsId];
    require(msg.value >= settings.requesterStake, "Not enough to cover stake");
    // used: true, disputed: false, processType: Removal 
    uint8 slotdata = paramsToSlotdata(true, false, ProcessType.Removal);
    slot.slotdata = slotdata;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    emit ItemRemovalRequest(_workSlot, _settingsId, _idSlot, _idRequestTime);
  }

  function editItem(uint64 _workSlot, uint48 _settingsId, uint64 _idSlot, uint40 _idRequestTime) public payable {
    Slot storage slot = slots[_workSlot];
    (bool used, , ) = slotdataToParams(slot.slotdata);
    require(used == false, "Slot must not be in use");
    Settings storage settings = settingsMap[_settingsId];
    require(msg.value >= settings.requesterStake, "Not enough to cover stake");
    // used: true, disputed: false, processType: Edit
    uint8 slotdata = paramsToSlotdata(true, false, ProcessType.Edit);
    slot.slotdata = slotdata;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    emit ItemEditRequest(_workSlot, _settingsId, _idSlot, _idRequestTime);
  }

  function executeRequest(uint64 _slotIndex) public {
    Slot storage slot = slots[_slotIndex];
    require(slotIsExecutable(slot), "Slot cannot be executed");
    Settings storage settings = settingsMap[slot.settingsId];
    payable(slot.requester).transfer(settings.requesterStake);
    emit RequestAccepted(_slotIndex);
    // used to false, others don't matter.
    slot.slotdata = paramsToSlotdata(false, false, ProcessType.Add);
  }

  function challengeRequest(uint64 _slotIndex, uint64 _disputeSlot) public payable {
    Slot storage slot = slots[_slotIndex];
    require(slotCanBeChallenged(slot), "Slot cannot be challenged");
    Settings storage settings = settingsMap[slot.settingsId];
    require(msg.value >= settings.challengerStake, "Not enough to cover stake");
    // TODO you need to check if the submission time has passed. because then, challenger cannot challenge
    // someone needs to execute the process.
    Dispute storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Free, "That dispute slot is being used");

    // it will be challenged now

    // arbitrator magic happens here (pay fees, maybe read how much juror fees are...)
    // and get disputeId so that you can store it, you know.
    // we try to create the dispute first, then update values here.

    //  weird edge cases:
    // with juror fees increasing, and item is quickly requested
    // before list settings are updated.
    // the item might not have enough in stake to pay juror fees, and this
    // would always fail. not sure how to proceed, then.
    // i wouldn't trust an arbitrator that can pull that off.

    (, , ProcessType processType) = slotdataToParams(slot.slotdata);
    uint8 newSlotdata = paramsToSlotdata(true, true, processType);

    slot.slotdata = newSlotdata;
    dispute.state = DisputeState.Ruling;
    dispute.nContributions = 0;
    dispute.slotId = _slotIndex;
    // round is 0, amount is in dispute.slotId -> slot.settings -> settings.challengerStake, party is challenger
    // so it's a waste to create a contrib. just integrate it with dispute slot.
    dispute.challenger = msg.sender;
  }

  function contribute(uint64 _disputeSlot, Party _party) public payable {
    Dispute storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Funding, "Dispute is not in funding state");
    // compress amount, possibly losing up to 4 gwei. they will be burnt.
    uint80 amount = uint80(msg.value >> AMOUNT_BITSHIFT);
    contributions[_disputeSlot][dispute.nContributions++] = Contribution({round: dispute.currentRound + 1, party: _party, contributor: msg.sender, amount: amount});
  }

  function startNextRound(uint64 _disputeSlot, uint64 _firstContributionForRound) public {
    Dispute storage dispute = disputes[_disputeSlot];
    uint8 nextRound = dispute.currentRound + 1; // to save gas with less storage reads
    require(dispute.state == DisputeState.Funding, "Dispute has to be on Funding");
    Contribution memory firstContribution = contributions[_disputeSlot][_firstContributionForRound];
    require(nextRound == firstContribution.round, "Contrib is for another round");
    // get required fees from somewhere. how? is it expensive? do I just calculate here?
    // look into this later. for now just make the total amount up.
    uint80 totalAmountNeeded = 3000;
    uint80 sumOfAmounts = firstContribution.amount;
    uint64 i = _firstContributionForRound;
    bool successFlag = false;
    for (; ; i++) {
      Contribution storage contribution = contributions[_disputeSlot][i];
      // break if round changes.
      // actually theres a better way to do this. fix this abomination.
      // you dont need to check round, you could just do the for until
      // you run out of nContributions
      // because you cannot bullshit the rounds anyway
      // no one can make a contribution with the wrong round.
      // todo
      if (nextRound != contribution.round) {
        break;
      }
      sumOfAmounts = sumOfAmounts + contribution.amount;
      // break if needed sum is reached
      if (sumOfAmounts >= totalAmountNeeded) {
        successFlag = true;
        break;
      }
    }
    require(successFlag, "Insufficient amount");
    uint256 actualAmount = totalAmountNeeded << uint80(AMOUNT_BITSHIFT);
    // something is done with the actual amount
    // its divided by something or whatever and you get the fees
    // or maybe you already know, and read from settings or a view func.
    // bs event to make VS Code shut up. TODO.
    emit RequestAccepted(uint64(actualAmount));
    // and then you call the function of the arbitrator with value equal to "actualAmount"
    // plus a few gwei, because we're may be losing to rounding errors.
    // or we could make contributors pay slightly more gwei just to always be on the safe side.
  }

  function executeRuling(uint64 _disputeSlot) public {
    //1. get arbitrator for that setting, and disputeId from disputeSlot.
    Dispute storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    //   2. make sure that disputeSlot has an ongoing dispute
    require(dispute.state == DisputeState.Funding, "Can only be executed in Funding");
    //    3. access storedRulings[arbitrator][disputeId]. make sure it's ruled.
    StoredRuling memory storedRuling = storedRulings[settings.arbitrator][dispute.arbitratorDisputeId];
    require(storedRuling.ruled, "Wasn't ruled by the arbitrator");
    //    4. apply ruling. what to do when refuse to arbitrate? dunno. maybe... just
    //    default to requester, in that case.
    // 0 refuse, 1 requester, 2 challenger.
    if (storedRuling.ruling == 1 || storedRuling.ruling == 0) {
      // requester won.
      emit RequestAccepted(dispute.slotId);
    } else {
      // challenger won.
      emit RequestRejected(dispute.slotId);
    }
    // 5. withdraw rewards
    withdrawRewards(_disputeSlot);
    // 6. dispute and slot are now Free.. other slotdata doesn't matter.
    slot.slotdata = paramsToSlotdata(false, false, ProcessType.Add);
    dispute.state = DisputeState.Free; // to avoid someone withdrawing rewards twice.
  }

  function rule(uint256 _disputeId, uint256 _ruling) external override {
    // no need to check if already ruled, every arbitrator is trusted.
    // arbitrators that "cheat" don't matter, no one will use them.
    storedRulings[msg.sender][_disputeId] = StoredRuling({ruling: _ruling, ruled: true});
    emit Ruling(IArbitrator(msg.sender), _disputeId, _ruling);
  }

  function withdrawRewards(uint64 _disputeSlot) private {
    // todo
    /*
            withdraw rewards
            ok whats the deal with this
            do arbitrator remember the fees they have for each dispute? is it different for each dispute?
            because this is pretty important actually
            if it doesn't remember, even if I query for fees every single time (which is super inefficient)
            I would be fucked up

            if they remember, you'd need to ask for fees:
            - when challenging
            - when withdrawing rewards, to substract the total cost of the dispute.
            (or, you could store the total cost somewhere in the dispute data.)
            - when advancing to next round.

            edge case:
            some settings don't work anymore
            because arbitrator changes fees while there's a submitted item
            and the submitter stake and challenger stake no longer cover the dispute, so it cannot start.
            in that case, we could revert and make it impossible to challenge. e.g. let submitter
            just pick up their reward. someone can create new settings, edit
            the settings of the list and then remove the item, so there's a workaround.
        */
  }

  // VIEW FUNCTIONS

  // relying on this by itself could result on users colliding on same slot
  // user which is late will have the transaction cancelled, but gas wasted and unhappy ux
  // could be used to make an "emergency slot", in case your slot submission was in an used slot.
  // will get the first Virgin, or Created slot.
  function firstFreeSlot(uint64 _startPoint) public view returns (uint64) {
    uint64 i = _startPoint;
    // this is used == true, because if used, slotdata is of shape 1xx00000, so it's larger than 127
    while (slots[i].slotdata > 127) {
      i = i + 1;
    }
    return i;
  }

  // debugging purposes, for now. shouldn't be too expensive and could be useful in future, tho
  // doesn't actually "count" the slots, just checks until there's a virgin slot
  // it's the same as "maxSlots" in the notes
  function firstVirginSlotFrom(uint64 _startPoint) public view returns (uint64) {
    uint64 i = _startPoint;
    while (slots[i].requester != address(0)) {
      i = i + 1;
    }
    return i;
  }

  // this is prob bloat. based on the idea of generating a random free slot, to avoid collisions.
  // could be used to advice the users to wait until there's free slot for gas savings.
  function countFreeSlots() public view returns (uint64) {
    uint64 slotCount = firstVirginSlotFrom(0);
    uint64 i = 0;
    uint64 freeSlots = 0;
    for (; i < slotCount; i++) {
      Slot storage slot = slots[i];
      // !slot.used ; so slotdata is smaller than 128
      if (slot.slotdata < 128) {
        freeSlots++;
      }
    }
    return freeSlots;
  }

  function viewSlot(uint64 _slotIndex) public view returns (Slot memory) {
    return slots[_slotIndex];
  }

  function slotIsExecutable(Slot memory _slot) public view returns (bool) {
    Settings storage settings = settingsMap[_slot.settingsId];
    bool overRequestPeriod = block.timestamp > _slot.requestTime + settings.requestPeriod;
    (bool used, bool disputed, ) = slotdataToParams(_slot.slotdata);
    return used && overRequestPeriod && !disputed;
  }

  function slotCanBeChallenged(Slot memory _slot) public view returns (bool) {
    Settings storage settings = settingsMap[_slot.settingsId];
    bool overRequestPeriod = block.timestamp > _slot.requestTime + settings.requestPeriod;
    (bool used, bool disputed, ) = slotdataToParams(_slot.slotdata);
    return used && !overRequestPeriod && !disputed;
  }

  // returns "slotdata" given parameters such as
  // used, processType and disputed, in a single encoded uint8.
  // TODO adapt for edit ProcessType (2 bits now)
  function paramsToSlotdata(
    bool _used,
    bool _disputed,
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

  // returns a tuple with these three from a given slotdata
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
}
