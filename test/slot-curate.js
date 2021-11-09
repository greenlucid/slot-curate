const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SlotCurate", () => {
  before("Deploying", async () => {
    [deployer, requester, challenger, innocentBystander, governor, anotherGovernor] = await ethers.getSigners();
    ({ arbitrator, slotCurate } = await deployContracts(deployer));
    requesterAddress = await requester.getAddress();
  });

  describe("Default", () => {
    const REQUESTER_STAKE = 1_000_000_000;
    const CHALLENGER_STAKE = 1_000_000_000;
    const REQUEST_PERIOD = 1_000;
    const FUNDING_PERIOD = 1_000;

    it("Should create settings.", async () => {
      const args = [REQUESTER_STAKE, REQUEST_PERIOD, "0x00", "add", "remove", "update"];

      await expect(slotCurate.connect(deployer).createSettings(...args))
        .to.emit(slotCurate, "SettingsCreated")
        .withArgs(...args.slice(0, 2));
    });

    it("Should initialize a list.", async () => {
      const args = [0, governor.address, "/ipfs/asdqwekmjk23jk4k2m342km342k3m4k23m4"];

      await expect(slotCurate.connect(deployer).createList(...args))
        .to.emit(slotCurate, "ListCreated")
        .withArgs(...args);
    });

    it("Should update not let updating a list unless caller is the governor.", async () => {
      const args = [0, 1, anotherGovernor.address, "/ipfs/asd2342342llllasxccxcck2m342km342k3m4k23m4"];

      await expect(slotCurate.connect(innocentBystander).updateList(...args)).to.be.revertedWith("You need to be the governor");
    });

    it("Should update a list.", async () => {
      const args = [0, 1, anotherGovernor.address, "/ipfs/asd2342342llllasxccxcck2m342km342k3m4k23m4"];

      await expect(slotCurate.connect(governor).updateList(...args))
        .to.emit(slotCurate, "ListUpdated")
        .withArgs(...args);
    });

    it("Should add item.", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await expect(slotCurate.connect(requester).addItem(...args, { value: REQUESTER_STAKE }))
        .to.emit(slotCurate, "ItemAddRequest")
        .withArgs(...args.slice(0, 4));
    });

    it("Should should not let you add an item using an occupied slot.", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await expect(slotCurate.connect(requester).addItem(...args)).to.be.reverted;
    });

    it("Should execute a request.", async () => {
      const args = [0];
      await ethers.provider.send("evm_increaseTime", [REQUEST_PERIOD]);
      await slotCurate.connect(requester).executeRequest(...args);
    });

    it("Should remove an item.", async () => {
      const args = [0, 0, 0, 0];

      await slotCurate.connect(requester).removeItem(...args, { value: REQUESTER_STAKE });
      await ethers.provider.send("evm_increaseTime", [REQUEST_PERIOD + 1]);
      await slotCurate.connect(requester).executeRequest(args[3]);
    });

    it("Should let you add an item using a freed slot.", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await slotCurate.connect(requester).addItem(...args, { value: REQUESTER_STAKE });
    });

    it("Should let you add an item, finding a vacant slot automatically.", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await slotCurate.connect(requester).addItemInFirstFreeSlot(...args, { value: REQUESTER_STAKE });
    });

    it("Should let you edit an item, finding a vacant slot automatically.", async () => {
      const args = [0, 0, 0, 0, "/ipfs/QmYs17mAJTabcabcabcabcabcabacaAjREeUdjJShNSeKh"];

      await slotCurate.connect(requester).editItemInFirstFreeSlot(...args, { value: REQUESTER_STAKE });
    });

    it("Should challenge an item.", async () => {
      const args = [0, 0];

      const CHALLENGE_FEE = await slotCurate.connect(innocentBystander).challengeFee(args[0]);

      await slotCurate.connect(requester).challengeRequest(...args, { value: CHALLENGE_FEE });
    });

    it("Should let others to contribute appeal fees of an item.", async () => {
      const args = [0, 0];

      const CHALLENGE_FEE = await slotCurate.connect(innocentBystander).challengeFee(args[0]);

      await slotCurate.connect(requester).challengeRequest(...args, { value: CHALLENGE_FEE });
    });
  });
});

async function deployContracts(deployer) {
  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer);
  const arbitrator = await Arbitrator.deploy();
  await arbitrator.deployed();

  const SlotCurate = await ethers.getContractFactory("SlotCurate", deployer);
  const slotCurate = await SlotCurate.deploy(governor.address, arbitrator.address);
  await slotCurate.deployed();

  return {
    arbitrator,
    slotCurate,
  };
}
