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
    put an extra byte to be in the same side. uint96.
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
*/

contract SlotCurate is IArbitrable {
  uint256 internal constant AMOUNT_BITSHIFT = 32; // this could make submitter lose up to 4 gwei
  uint256 internal constant RULING_OPTIONS = 2;
  uint256 internal constant DIVIDER = 1000000;

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

  // settings cannot be mutated once created, otherwise pending processes could get attacked.
  struct Settings {
    uint80 requesterStake;
    uint80 challengerStake;
    uint40 requestPeriod;
    uint40 fundingPeriod;
    uint16 freeSpace2;
    IArbitrator arbitrator;
    uint64 multiplier; // divide by DIVIDER for float.
    uint32 freeSpace;
    bytes32 arbitratorExtraData1;
    bytes32 arbitratorExtraData2;
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
  // takes 3 slots
  struct Dispute {
    uint256 arbitratorDisputeId; // required
    uint64 slotId; // flexible
    address challenger; // store it here instead of contributions[dispute][0]
    DisputeState state;
    uint8 currentRound;
    bool pendingInitialWithdraw;
    uint8 freeSpace;
    uint64 nContributions;
    uint64 pendingWithdraws; 
    uint40 timestamp; // to derive
    uint80 roundZeroCost; // to distribute requester / challenger reward. sure you need this?
    uint8 freeSpace2;
  }

  struct Contribution {
    uint8 round; // could be bigger, there's enough space by shifting amount.
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
    uint256 ruling;
    bool ruled; // this bit costs 20k gas (ferit: bool is uint8 under the hood, don't forget.)
  }

  // EVENTS //

  event ListCreated(uint48 _settingsId, address _governor, string _ipfsUri);
  event ListUpdated(uint64 _listIndex, uint48 _settingsId, address _governor);
  // _requesterStake, _challengerStake, _requestPeriod, _fundingPeriod, _arbitrator
  event SettingsCreated(uint256 _requesterStake, uint256 _challengerStake, uint40 _requestPeriod, uint40 _fundingPeriod, address _arbitrator);
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
  mapping(uint64 => mapping(uint64 => Contribution)) internal contributions; // contributions[disputeSlot][n]
  // totalContributions[disputeId][round][Party]
  mapping(uint64 => mapping(uint8 => RoundContributions)) internal roundContributionsMap;
  mapping(address => mapping(uint256 => StoredRuling)) internal storedRulings; // storedRulings[arbitrator][disputeId]

  // PUBLIC FUNCTIONS

  // lists
  function createList(
    address _governor,
    uint48 _settingsId,
    string memory _ipfsUri
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
    uint80 _requesterStake,
    uint80 _challengerStake,
    uint40 _requestPeriod,
    uint40 _fundingPeriod,
    address _arbitrator
  ) public {
    // require is not used. there can be up to 281T.
    // that's 1M years of full 15M gas blocks every 13s.
    // skipping it makes this cheaper. overflow is not gonna happen.
    // a rollup in which this was a risk might be possible, but then just remake the contract.
    // require(settingsCount != type(uint48).max, "Max settings reached");
    Settings storage settings = settingsMap[settingsCount++];
    settings.requesterStake = _requesterStake;
    settings.challengerStake = _challengerStake;
    settings.requestPeriod = _requestPeriod;
    settings.fundingPeriod = _fundingPeriod;
    settings.arbitrator = IArbitrator(_arbitrator);
    emit SettingsCreated(_requesterStake, _challengerStake, _requestPeriod, _fundingPeriod, _arbitrator);
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
    
    Dispute storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Free, "That dispute slot is being used");

    // it will be challenged now

    bytes memory arbitratorExtraData = bytes.concat(settings.arbitratorExtraData1, settings.arbitratorExtraData2);

    uint256 arbitrationCost = settings.arbitrator.arbitrationCost(arbitratorExtraData);

    // make sure stake covers arbitrationCost * multiplier! (why? because fees may change)
    // uint totalInitialStake = decompressAmount(settings.requesterStake) + msg.value
    // notice the difference. above is what could be used to have a workaround on
    // "arbitrator changed juror fees" edge case. that way challenger can just stake
    // any arbitrary amount, that added to requester stake makes the minimum cut.
    // but that will require removing "challenger stake" from settings,
    // and storing the challenger stake per dispute which is going to be more expensive.
    // alt, you can have the requester + msg.value, and the excess is burnt.
    // or if juror fees become too high, lost.
    uint totalInitialStake = decompressAmount(settings.requesterStake + settings.challengerStake) * settings.multiplier / DIVIDER;
    require(compressAmount(arbitrationCost) <= totalInitialStake, "Not enough for stake");

    // actually call dispute
    uint arbitratorDisputeId = settings.arbitrator.createDispute
      { value: arbitrationCost }
      (RULING_OPTIONS,arbitratorExtraData);

    (, , ProcessType processType) = slotdataToParams(slot.slotdata);
    uint8 newSlotdata = paramsToSlotdata(true, true, processType);

    slot.slotdata = newSlotdata;
    dispute.arbitratorDisputeId = arbitratorDisputeId;
    dispute.slotId = _slotIndex;
    dispute.challenger = msg.sender;
    dispute.state = DisputeState.Ruling;
    dispute.currentRound = 0;
    dispute.pendingInitialWithdraw = true;
    dispute.nContributions = 0;
    dispute.pendingWithdraws = 0;
    dispute.timestamp = uint40(block.timestamp);
    dispute.roundZeroCost = compressAmount(arbitrationCost);
  }

  function contribute(uint64 _disputeSlot, Party _party) public payable {
    Dispute storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Funding, "Dispute is not in funding state");
    // todo make sure its also under period?
    uint8 nextRound = dispute.currentRound + 1;
    uint8 contribdata = paramsToContribdata(false, _party);
    dispute.nContributions++;
    dispute.pendingWithdraws++;
    // compress amount, possibly losing up to 4 gwei. they will be burnt.
    uint80 amount = compressAmount(msg.value);
    roundContributionsMap[_disputeSlot][nextRound].partyTotal[uint(_party)] += amount;
    contributions[_disputeSlot][dispute.nContributions++] = Contribution({round: nextRound, contribdata: contribdata, contributor: msg.sender, amount: amount});
  }

  function startNextRound(uint64 _disputeSlot) public {
    Dispute storage dispute = disputes[_disputeSlot];
    uint8 nextRound = dispute.currentRound + 1; // to save gas with less storage reads
    Slot storage slot = slots[dispute.slotId];
    Settings storage settings = settingsMap[slot.settingsId];
    require(dispute.state == DisputeState.Funding, "Dispute has to be on Funding");
    require(block.timestamp < uint(dispute.timestamp + settings.fundingPeriod), "Over funding period");
    
    bytes memory arbitratorExtraData = bytes.concat(settings.arbitratorExtraData1, settings.arbitratorExtraData2);
    uint appealCost = settings.arbitrator.appealCost(dispute.arbitratorDisputeId, arbitratorExtraData);
    uint totalAmountNeeded = appealCost * settings.multiplier / DIVIDER;

    // make sure you have the required amount
    uint currentAmount = decompressAmount(roundContributionsMap[_disputeSlot][nextRound].partyTotal[0] + roundContributionsMap[_disputeSlot][nextRound].partyTotal[1]);
    require(currentAmount >= totalAmountNeeded, "Not enough to fund round");
    // mmm............
    // apparently I have to do something related to "currentRuling"....
    // TODO

    /*
      ok, at a high level this is how it works:
      whenever people make settings, make sure settings.fundingPeriod is > rulingPeriod of arbor
      disputestatus.RULING doesnt exist anymore. just let people contribute even if
      theres not an updated ruling yet. even if they're disputing, why wait?
      this is because you cant get period from arble.

    */

    // bs event to make VS Code shut up. TODO.
    emit RequestAccepted(uint64(currentAmount));
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
    StoredRuling memory storedRuling = storedRulings[address(settings.arbitrator)][dispute.arbitratorDisputeId];
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
    // this is used == true, because if used, slotdata is of shape 1xxx0000, so it's larger than 127
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

  function paramsToContribdata(bool _withdrawn, Party _party) public pure returns (uint8) {
    uint8 withdrawnAddend;
    if (_withdrawn) withdrawnAddend = 128;
    uint8 partyAddend;
    if (_party == Party.Challenger) partyAddend = 64;

    uint8 contribdata = withdrawnAddend + partyAddend;
    return contribdata;
  }

  function contribdataToParams(uint8 _contribdata) public pure returns (bool, Party) {
    uint8 withdrawnAddend = _contribdata & 128;
    bool withdrawn = withdrawnAddend != 0;
    uint8 partyAddend = _contribdata & 64;
    Party party = Party(partyAddend >> 6);

    return (withdrawn, party);
  }

  // always compress / decompress rounding down. 
  function compressAmount(uint _amount) public pure returns (uint80) {
    return (uint80(_amount >> AMOUNT_BITSHIFT));
  }

  function decompressAmount(uint80 _compressedAmount) public pure returns (uint) {
    return (uint(_compressedAmount) << AMOUNT_BITSHIFT);
  }
}
