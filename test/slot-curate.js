const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SlotCurate", () => {
  before("Deploying", async () => {
    [deployer, requester, challenger, innocentBystander] = await ethers.getSigners();
    ({ arbitrator, slotCurate } = await deployContracts(deployer));
    requesterAddress = await requester.getAddress();
  });

  describe("Default", () => {
    const REQUESTER_STAKE = 1_000_000_000;
    const CHALLENGER_STAKE = 1_000_000_000;
    const REQUEST_PERIOD = 1_000;
    const FUNDING_PERIOD = 1_000;

    it("Should create settings", async () => {
      const args = [REQUESTER_STAKE, CHALLENGER_STAKE, REQUEST_PERIOD, FUNDING_PERIOD, arbitrator.address, "0x00", "add", "remove", "update"];

      await expect(slotCurate.connect(deployer).createSettings(...args))
        .to.emit(slotCurate, "SettingsCreated")
        .withArgs(...args.slice(0, 5));
    });

    it("Should add item", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await expect(slotCurate.connect(requester).addItem(...args, { value: REQUESTER_STAKE }))
        .to.emit(slotCurate, "ItemAddRequest")
        .withArgs(...args.slice(0, 4));
    });

    it("Should should not let you add an item using an occupied slot", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await expect(slotCurate.connect(requester).addItem(...args)).to.be.reverted;
    });

    it("Should execute a request", async () => {
      const args = [0];
      await ethers.provider.send("evm_increaseTime", [REQUEST_PERIOD]);
      await slotCurate.connect(requester).executeRequest(...args);
    });

    it("Should should let you add an item using a freed slot", async () => {
      const args = [0, 0, 0, "/ipfs/QmYs17mAJTaQwYeXNTb6n4idoQXmRcAjREeUdjJShNSeKh"];

      await slotCurate.connect(requester).addItem(...args, { value: REQUESTER_STAKE });
    });
  });
});

async function deployContracts(deployer) {
  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer);
  const arbitrator = await Arbitrator.deploy();
  await arbitrator.deployed();

  const SlotCurate = await ethers.getContractFactory("SlotCurate", deployer);
  const slotCurate = await SlotCurate.deploy();
  await slotCurate.deployed();

  return {
    arbitrator,
    slotCurate,
  };
}
