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

    whats the point of forcing listCount to uint64?
    there's no saving. maybe in rollups, someday?

    if needed, you can store eth amounts as uint64.
    rationale: uint88 is enough to index all current wei
    put an extra byte to be in the safe side. uint96.
    discard the 4 gwei residue. it's uint64 now.

    ok, i have to save the total amount contributed per side per round.
    disputeId -> uint8 -> uint80[2]
    totalContribution[disputeId][round][party]
    but also cannot afford to have the storage slot reset to 0 every time.

    having it as a mapping is more expensive than an array, isn't it?
    because you have to put the keys onto storage as well. not sure! check.
    because all structs are crafted to fit in exact number of slots. so if you can skip
    storing keys, go for it.
    somehow I doubt it's possible
    I'm defo not storing TWO storage slots because then it'd be >60k.


    remember to set the successor totalParties to zero on challenge, and on startNextRound

    put more stuff into "totalContributions". rename it to "roundContributions" or something.
    since I'm doing this anyway, let's just store the number of contributions in the round.
    why? because of the following edge case.
    say contribs are like this:
    11112222222223333333333333
    ok. and in the threes, there's enough
    lets say there's enough with the starting 4 threeses...
    yeah its not really a problem. we've already accepted this. contributions per the round may be
    overpayed, and what will happen is that they will split the funds proportionally.

    this is not really needed... you could just check if there's already enough to crowdfund for that round. no need for madness.
    because we can check the total amount needed per party per round, right?
    problem is we can only know for certain if we call the "calculate cost" function
    and if we have to do that PER contribution then it will get so expensive.
    so... lets go back to previous idea. read above.

    fuck it, I don't care about it. lets ignore this and just remember about it
    and talk about it later to check again if this is a problem.
    it'd be easy to accomodate a solution if it was troublesome.

    maybe I should check if thing is ruled before allowing rule.
    and maybe I should have some timestamp thing to make sure arbitrator doesnt cheat
    but really, whats the point of using an arbitrator if im going to write internal logic?
    it was about trust. i dont want to overengineer this contract.


    the whole "contribute a certain amount for x side" thing is not needed.
    just check if you contribute the minimum required to advance for next round,
    (this could be hardcoded, or customizable per setting. calculated as multiplier of appealCost)
    when the dispute is resolved just split the spoils proportionally to the winning side.
    edit: I understand it may need a "leap of faith" to believe that the incentives are set up correctly
    but really, there are similarities with prediction markets
    say contributor for challenger puts 2/3 of the amount needed
    why would someone contribute for requester? if no one contributes, then requester wins automatically.
    so its beneficial for requester and all previous requester contributors
    but say someone believes in their side. then they just stake more.
    if one side funded all of a round and lost, then the surplus would just get stuck inside the contract.
    which you could collect as dev by making a function to cashout a round with this characteristic.
    to governor or whatever


    hey, for withdrawing in a round that wasnt completely funded,
    dont do it like first version of curate, in which you couldn't get your contribution back.
    get some way to get the funds out.
    this means that when withdrawAllContributions finds a contrib for a round
    that never got disputed
    then you stop checking for "winner", and just refund all contribs for that round.
    e.g. send amount.

    what to do when refuse to arbitrate is final? it just defaults to requester, so requester always has an edge.
    it could default to challenger instead.

    to make sure this is always infallible, store the cost of the appeal the moment it's actually done.
    store it in RoundContributions
    so whenever theres a withdrawal for one contribution (assume called the public version)
    make sure its pending withdrawal
    make sure its winning side
    make sure contribution id is below nContributions
    make sure pendingContributions != 0
    get spoils by adding the two party amount, substracting appealCost
    share = spoils * contribution.amount / partyTotal[winningParty]
    send to contributor.
    set contribution as withdrawn.
    decrease pendingWithdrawals

    advance Next Round:
    check appeal cost
    multiply it by surplusMultiplier (which is forcibly >1.5 or so. could fit uint8
    by using low level hacking. say you use 4 bits as fractionary part.
    alternatively, use uint16, uint24. because say there are very cheap appeal costs,
    but list owner wants quite a lot of stake in the game. so that they can go higher.
    uint32 sounds legit for extremely cheap disputes. 4 bits is still enough to store the fractionary part.
    this multiplier approach will be limiting. its dependant on appeal cost
    is there a way to make it fixed cost, or fixed increasing cost, somehow?
    whatever, there's a way around that, just migrate to new settings with new cost.


    make a lighter, private version of this that works without the first two conditions, 
    and without setting contribution as withdrawn & without decreasing pendingWithdrawals
    , to use in withdrawAllContributions.
    then you can just write: pendingContributions = 0 at the end, that it has been completely withdrawn already.

    you could check if a contribution is withdrawable if contribdata == some number. 128 or 192 depending
    on winning party.
    instead of storing it as a variable and reading from it, have an initial branch between parties.
    and just check contribdata == 128.
    that should save ~10 gas per iteration (xD)



    also withdraw the zero round, if pending. (0 withdrawn, 1 pending)

    wait. what about the "zero round"? you could have a 1 bit flag to check for that, in the dispute.

    you can only challenge in a dispute slot if pendingContributions = 0 and zero round has been withdrawn.

    store first round cost in dispute slot, so that you can tell how much to spoil away.

    how does "rule" work. is it at the end of each appeal
    or is it at the end of all, and it's final?
    because I've assumed 2nd one. but that's probably not right, is it?
    how does my contract get the information that the round has finished?
    i need it to get timestamp
    curate used this to know who had to contribute more for next round.



    how to do the fundingPeriod contribute, appeal logic
    if calling "appealPeriod" is cheap:
    just query every contribute or appeal func.

    if it's expensive:
    check "appealDeadline" (the timestamp in dispute)
    if you're over it, call appealPeriod. if 0, 0, you can't contribute or appeal.
    if you get something different, you check if you're under "end".
    if so, rewrite appealDeadline with end.
    otherwise, revert.

    actually i dont need to store uint256 rulings XD
    (in curate) there are only 3 possible rulings.
    just store it in a single slot.

    remember to make "withdrawRoundZero". unsure if I already wrote this down.

    i think you could get away with not reading settings for requesterStake
    if instead you read the msg.value from the event and check yourself if it matches the required amount
    if it doesn't, ignore it in subgraph and frontend
    whoever chooses to interact with it, it's at risk.
    mm... that may force to save amount somewhere, like the slot
    otherwise if it gets "resolved" then the requester can drain value
    i dont think that is feasible
    (check later how much would this save. if it's over 1k gas, consider.)
    
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
    Free, // you can take slot
    Used
  }

  // settings cannot be mutated once created, otherwise pending processes could get attacked.
  struct Settings {
    uint80 requesterStake;
    uint40 requestPeriod;
    uint40 fundingPeriod;
    uint96 freeSpace2;
    IArbitrator arbitrator;
    uint64 multiplier; // divide by DIVIDER for float.
    uint32 freeSpace;
    bytes arbitratorExtraData;
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
  // _requesterStake, _challengerStake, _requestPeriod, _fundingPeriod, _arbitrator
  event SettingsCreated(uint256 _requesterStake, uint256 _challengerStake, uint40 _requestPeriod, uint40 _fundingPeriod, IArbitrator _arbitrator);
  // why emit settingsId in the request events?
  // it's cheaper to trust the settingsId in the contract, than read it from the list and verifying
  // the subgraph can check the list at that time and ignore requests with invalid settings.
  // this will be bad in rollups
  // TODO verify this experimentally, because it might not be the case. its bad to emit more than needed
  // you could check if listId < listCount in subgraph, and ignore
  // and do settingsId = list[listId].settingsId
  // requesterStake = settingsMap[settingsId].requesterStake
  // slot.settingsId = settingsId
  // also check how expensive is to check listId < listcount in contract!!!!! TODO
  // because then you wont have to deal with it at subgraph level -AT ALL-

  // YOU CAN SAVE 1k by compressing data before emitting the event
  // because of how topics work
  // compress all small params into one bytes32. deal with it in subgraph.
  event ItemAddRequest(uint64 _listIndex, uint48 _settingsId, uint64 _idSlot, string _ipfsUri);
  event ItemRemovalRequest(uint64 _workSlot, uint48 _settingsId, uint64 _listId, uint64 _itemId);
  event ItemEditRequest(uint64 _workSlot, uint48 _settingsId, uint64 _listId, uint64 _itemId, string _ipfsUri);
  // you don't need different events for accept / reject because subgraph remembers the progress per slot.
  event RequestAccepted(uint64 _slotIndex);
  event RequestRejected(uint64 _slotIndex);
  event WhitelistChange(address _arbitrator, bool _status);
  event GovernorChange(address _governor);

  // CONTRACT STORAGE //

  address internal governor; // governor can whitelist arbitrators.
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
  mapping(address => mapping(uint256 => StoredRuling)) internal storedRulings; // storedRulings[arbitrator][disputeId]
  mapping(address => bool) internal arbitratorsWhitelist; // to restrict reusing disputeSlots. you don't need to be in for creating new.

  constructor(address _governor) {
    governor = _governor;
  }

  // PUBLIC FUNCTIONS

  // lists
  function createList(
    address _governor,
    uint48 _settingsId,
    string calldata _ipfsUri
  ) public {
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
  ) public {
    List storage list = lists[_listIndex];
    require(msg.sender == list.governor, "You need to be the governor");
    list.governor = _newGovernor;
    list.settingsId = _settingsId;
    emit ListUpdated(_listIndex, _settingsId, _newGovernor, _ipfsUri);
  }

  // settings
  // bit of a draft since I havent done the dispute side of things yet
  function createSettings(
    uint80 _requesterStake,
    uint40 _requestPeriod,
    uint40 _fundingPeriod,
    IArbitrator _arbitrator,
    bytes calldata _arbitratorExtraData,
    string memory _addMetaEvidence,
    string memory _removeMetaEvidence,
    string memory _updateMetaEvidence
  ) public {
    // require is not used. there can be up to 281T.
    // that's 1M years of full 15M gas blocks every 13s.
    // skipping it makes this cheaper. overflow is not gonna happen.
    // a rollup in which this was a risk might be possible, but then just remake the contract.
    // require(settingsCount != type(uint48).max, "Max settings reached");
    Settings storage settings = settingsMap[settingsCount++];
    settings.requesterStake = _requesterStake;
    settings.requestPeriod = _requestPeriod;
    settings.fundingPeriod = _fundingPeriod;
    settings.arbitrator = _arbitrator;
    settings.arbitratorExtraData = _arbitratorExtraData;

    emit MetaEvidence(3 * settingsCount, _addMetaEvidence);
    emit MetaEvidence(3 * settingsCount + 1, _removeMetaEvidence);
    emit MetaEvidence(3 * settingsCount + 1, _updateMetaEvidence);
    emit SettingsCreated(_requesterStake, _requestPeriod, _fundingPeriod, _arbitrator);
  }

  // no refunds for overpaying. consider it burned. refunds are bloat.

  // in the contract, listIndex and settingsId are trusted.
  // but in the subgraph, if listIndex doesnt exist or settings are not really the ones on list
  // then item will be ignored or marked as invalid.
  function addItem(
    uint64 _listIndex,
    uint48 _settingsId,
    uint64 _idSlot,
    string calldata _ipfsUri
  ) public payable {
    Slot storage slot = slots[_idSlot];
    // If free, it is of form 0xxx0000, so it's smaller than 128
    require(slot.slotdata < 128, "Slot must not be in use");
    Settings storage settings = settingsMap[_settingsId];
    require(msg.value >= settings.requesterStake, "Not enough to cover stake");
    // used: true, disputed: false, processType: Add
    uint8 slotdata = paramsToSlotdata(true, false, ProcessType.Add);
    slot.slotdata = slotdata;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    emit ItemAddRequest(_listIndex, _settingsId, _idSlot, _ipfsUri);
  }

  // frontrunning protection
  function addItemInFirstFreeSlot(
    uint64 _listIndex,
    uint48 _settingsId,
    uint64 _fromSlot,
    string calldata _ipfsUri
  ) public payable {
    uint64 workSlot = firstFreeSlot(_fromSlot);
    addItem(_listIndex, _settingsId, workSlot, _ipfsUri);
  }

  // list is checked in subgraph. settings is trusted here.
  // if settings was not the one settings in subgraph at the time,
  // then subgraph will ignore the removal (so it has no effect when exec.)
  // could even be challenged as an ilegal request to extract the stake, if significant.

  // TODO ponder about using workSlot, listId and itemId instead.
  // because these are given by the subgraph
  function removeItem(
    uint64 _workSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId
  ) public payable {
    Slot storage slot = slots[_workSlot];
    // If free, it is of form 0xxx0000, so it's smaller than 128
    require(slot.slotdata < 128, "Slot must not be in use");
    Settings storage settings = settingsMap[_settingsId];
    require(msg.value >= settings.requesterStake, "Not enough to cover stake");
    // used: true, disputed: false, processType: Removal
    uint8 slotdata = paramsToSlotdata(true, false, ProcessType.Removal);
    slot.slotdata = slotdata;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    emit ItemRemovalRequest(_workSlot, _settingsId, _listId, _itemId);
  }

  function removeItemInFirstFreeSlot(
    uint64 _fromSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId
  ) public payable {
    uint64 workSlot = firstFreeSlot(_fromSlot);
    removeItem(workSlot, _settingsId, _listId, _itemId);
  }
  
  function editItem(
    uint64 _workSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId,
    string calldata _ipfsUri
  ) public payable {
    Slot storage slot = slots[_workSlot];
    // If free, it is of form 0xxx0000, so it's smaller than 128
    require(slot.slotdata < 128, "Slot must not be in use");
    Settings storage settings = settingsMap[_settingsId];
    require(msg.value >= settings.requesterStake, "Not enough to cover stake");
    // used: true, disputed: false, processType: Edit
    uint8 slotdata = paramsToSlotdata(true, false, ProcessType.Edit);
    slot.slotdata = slotdata;
    slot.requestTime = uint40(block.timestamp);
    slot.requester = msg.sender;
    slot.settingsId = _settingsId;
    emit ItemEditRequest(_workSlot, _settingsId, _listId, _itemId, _ipfsUri);
  }

  function editItemInFirstFreeSlot(
    uint64 _fromSlot,
    uint48 _settingsId,
    uint64 _listId,
    uint64 _itemId,
    string calldata _ipfsUri
  ) public payable {
    uint64 workSlot = firstFreeSlot(_fromSlot);
    editItem(workSlot, _settingsId, _listId, _itemId, _ipfsUri);
  }

  function executeRequest(uint64 _slotIndex) public {
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

    if (dispute.challenger != address(0)) {
      // non-virgin dispute slot.
      require(arbitratorsWhitelist[address(settings.arbitrator)], "Cannot reuse, not in whitelist");
    }

    // dont require enough to cover arbitration fees
    // arbitrator will already take care of it
    // challenger pays arbitration fees + gas costs fully

    uint arbitratorDisputeId = settings.arbitrator.createDispute
      { value: msg.value }
      (RULING_OPTIONS,settings.arbitratorExtraData);

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
    // reconsider changing this. because right now you're making challenger pay for it!
    // but, who else will pay for it?
    // will be 5k in reused. but 20k in new.
    RoundContributions storage roundContributions = roundContributionsMap[_disputeSlot][1];
    roundContributions.filler = 1;
    roundContributions.appealCost = 0;
    roundContributions.partyTotal[0] = 0;
    roundContributions.partyTotal[1] = 0;
  }

  function challengeRequestInFirstFreeSlot(uint64 _slotIndex, uint64 _fromSlot) public payable {
    uint64 disputeWorkSlot = firstFreeDisputeSlot(_fromSlot);
    challengeRequest( _slotIndex, disputeWorkSlot);
  }

  function contribute(uint64 _disputeSlot, Party _party) public payable {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    require(dispute.state == DisputeState.Used, "DisputeSlot has to be used");

    _verifyUnderAppealDeadline(dispute, settings.arbitrator);

    uint8 nextRound = dispute.currentRound + 1;
    uint8 contribdata = paramsToContribdata(true, _party);
    dispute.nContributions++;
    dispute.pendingWithdraws++;
    // compress amount, possibly losing up to 4 gwei. they will be burnt.
    uint80 amount = compressAmount(msg.value);
    roundContributionsMap[_disputeSlot][nextRound].partyTotal[uint(_party)] += amount;
    contributions[_disputeSlot][dispute.nContributions++] = Contribution({round: nextRound, contribdata: contribdata, contributor: msg.sender, amount: amount});
  }

  function startNextRound(uint64 _disputeSlot) public {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    uint8 nextRound = dispute.currentRound + 1; // to save gas with less storage reads
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    require(dispute.state == DisputeState.Used, "DisputeSlot has to be Used");
    
    _verifyUnderAppealDeadline(dispute, settings.arbitrator);
    
    uint appealCost = settings.arbitrator.appealCost(dispute.arbitratorDisputeId, settings.arbitratorExtraData);
    uint totalAmountNeeded = appealCost * settings.multiplier / DIVIDER;

    // make sure you have the required amount
    uint currentAmount = decompressAmount(
      roundContributionsMap[_disputeSlot][nextRound].partyTotal[0] +
      roundContributionsMap[_disputeSlot][nextRound].partyTotal[1]
    );
    require(currentAmount >= totalAmountNeeded, "Not enough to fund round");
    
    // got enough, it's legit to do so. I can appeal, lets appeal
    settings.arbitrator.appeal
      {value: appealCost}
      (dispute.arbitratorDisputeId, settings.arbitratorExtraData);

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
    //1. get arbitrator for that setting, and disputeId from disputeSlot.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    // 2. make sure that disputeSlot has an ongoing dispute
    require(dispute.state == DisputeState.Used, "Can only be executed if Used");
    // 3. access storedRulings[arbitrator][disputeId]. make sure it's ruled.
    StoredRuling storage storedRuling = storedRulings[address(settings.arbitrator)][dispute.arbitratorDisputeId];
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
    // no need to check if already ruled, every arbitrator is trusted.
    // arbitrators that "cheat" don't matter, no one will use them.
    storedRulings[msg.sender][_disputeId] = StoredRuling({ruling: uint240(_ruling), ruled: true, executed: false});
    emit Ruling(IArbitrator(msg.sender), _disputeId, _ruling);
  }

  function withdrawOneContribution(uint64 _disputeSlot, uint64 _contributionSlot) public {
    // check if dispute is used.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    // withdrawAllRewards does not set the flag on "withdrawn" individually.
    // that's why you check for dispute as well.
    require(dispute.state == DisputeState.Used, "DisputeSlot must be in use");
    require(dispute.nContributions > _contributionSlot, "DisputeSlot lacks that contrib");
    // to check if dispute is really over. 
    StoredRuling storage storedRuling = 
      storedRulings[address(settings.arbitrator)][dispute.arbitratorDisputeId];
    require(storedRuling.ruled && storedRuling.executed, "Must be ruled and executed");

    Contribution storage contribution = contributions[_disputeSlot][_contributionSlot];
    (bool pendingWithdrawal, Party party) = contribdataToParams(contribution.contribdata);

    require(pendingWithdrawal, "Contribution withdrawn already");

    // okay, all checked. let's get the contribution.

    RoundContributions memory roundContributions =
      roundContributionsMap[_disputeSlot][contribution.round];

    if (roundContributions.appealCost != 0) {
      // then this is a contribution from an appealed round.
      // only winner party can withdraw.
      require(party == whichPartyWon(storedRuling.ruling), "That side lost the dispute");

      _withdrawSingleReward(contribution, roundContributions, party);
    } else {
      // this is a contrib from a round that didnt get appealed.
      // just refund the same amount
      uint refund = decompressAmount(contribution.amount);
      payable(contribution.contributor).transfer(refund);
    }

    if (dispute.pendingWithdraws == 1 && !dispute.pendingInitialWithdraw) {
      // this was last contrib remaining
      // no need to decrement pendingWithdraws if last. save gas.
      dispute.state = DisputeState.Free;
    } else {
      dispute.pendingWithdraws--;
    }
  }

  function withdrawRoundZero(uint64 _disputeSlot) public {
    // "round zero" refers to the initial requester, challenger stake.
    // it's not stored like the other contributions.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    
    require(dispute.state == DisputeState.Used, "DisputeSlot must be in use");
    // to check if dispute is really over. 
    StoredRuling storage storedRuling = 
      storedRulings[address(settings.arbitrator)][dispute.arbitratorDisputeId];
    require(storedRuling.ruled && storedRuling.executed, "Must be ruled and executed");
    require(dispute.pendingInitialWithdraw, "Round zero was already withdrawn");

    // withdraw it. this can be put onto its own private func.

    Party party = whichPartyWon(storedRuling.ruling);
    _withdrawRoundZero(dispute, settings, slot, party);

    if (dispute.pendingWithdraws == 0) {
      dispute.state = DisputeState.Free;
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
    StoredRuling storage storedRuling = 
      storedRulings[address(settings.arbitrator)][dispute.arbitratorDisputeId];
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
    RoundContributions memory roundContributions =
      roundContributionsMap[_disputeSlot][currentRound];
    // 2.1. the fully funded and appealed rounds
    // withdraw to pending winners
    while (contribSlot < dispute.nContributions) {
      Contribution memory contribution = contributions[_disputeSlot][contribSlot];
      if (contribution.round != currentRound) {
        roundContributions = 
          roundContributionsMap[_disputeSlot][contribution.round];
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

  // governor functions

  function changeWhitelist(address _arbitrator, bool _status) public {
    require(msg.sender == governor, "Only governor changes this");
    arbitratorsWhitelist[_arbitrator] = _status;
    emit WhitelistChange(_arbitrator, _status);
  }

  function changeGovernor(address _governor) public {
    require(msg.sender == governor, "Only governor changes this");
    governor = _governor;
    emit GovernorChange(_governor);
  }

  // PRIVATE FUNCTIONS

  // can mutate storage. reverts if not under appealDeadline
  function _verifyUnderAppealDeadline(DisputeSlot storage _dispute, IArbitrator _arbitrator) private {
    if (block.timestamp >= _dispute.appealDeadline) {
      // you're over it. get updated appealPeriod
      (, uint end) = _arbitrator.appealPeriod(_dispute.arbitratorDisputeId);
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
    uint amount = decompressAmount(_settings.requesterStake);
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
    uint spoils = decompressAmount(
        _roundContributions.partyTotal[0]
        + _roundContributions.partyTotal[1]
        - _roundContributions.appealCost
      );
    uint share = spoils 
      * uint(_contribution.amount)
      / uint(_roundContributions.partyTotal[uint(_winningParty)]);
    payable(_contribution.contributor).transfer(share);
  }

  function _refundContribution(
    Contribution memory _contribution
  ) private {
    uint refund = decompressAmount(_contribution.amount);
    payable(_contribution.contributor).transfer(refund);
  }
  
  function submitEvidence(uint64 _disputeSlot, string calldata _evidenceURI) external {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];

    emit Evidence(IArbitrator(settings.arbitrator), dispute.arbitratorDisputeId, msg.sender, _evidenceURI);
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
    return used
      && (block.timestamp > _slot.requestTime + requestPeriod)
      && !disputed;
  }

  function slotCanBeChallenged(Slot memory _slot, uint40 requestPeriod) public view returns (bool) {
    (bool used, bool disputed, ) = slotdataToParams(_slot.slotdata);
    return used
      && !(block.timestamp > _slot.requestTime + requestPeriod)
      && !disputed;
  }

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
  function compressAmount(uint _amount) public pure returns (uint80) {
    return (uint80(_amount >> AMOUNT_BITSHIFT));
  }

  function decompressAmount(uint80 _compressedAmount) public pure returns (uint) {
    return (uint(_compressedAmount) << AMOUNT_BITSHIFT);
  }

  // thanks to this func we could possibly do without the above func.
  function whichPartyWon(uint248 _ruling) public pure returns (Party) {
    if (_ruling == 0 || _ruling == 1) {
      return Party.Requester;
    } else {
      return Party.Challenger;
    }
  }
}
