import chai, { expect } from "chai";
import { ethers, waffle } from "hardhat";
import { solidity } from "ethereum-waffle";
import { BigNumberish, ContractTransaction } from "ethers";

import { setNextBlockTimestamp } from "../utils";

import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import type { AtlasMineStaker } from "../../src/types/AtlasMineStaker";
import type { MasterOfCoin } from "../../src/types/MasterOfCoin";
import type { MockLegionMetadataStore } from "../../src/types/MockLegionMetadataStore";
import type { AtlasMine } from "../../src/types/AtlasMine";
import type { TestERC20 } from "../../src/types/TestERC20";
import type { TestERC1155 } from "../../src/types/TestERC1155";
import type { TestERC721 } from "../../src/types/TestERC721";

chai.use(solidity);

export const ether = ethers.utils.parseEther;
export const TOTAL_REWARDS = ether("172800");
export const ONE_DAY_SEC = 86400;

/////////////////////////////////////////////////////////////////////////////////
///                                  TYPES                                    ///
/////////////////////////////////////////////////////////////////////////////////

export interface TestContext {
    signers: SignerWithAddress[];
    admin: SignerWithAddress;
    users: SignerWithAddress[];
    staker: AtlasMineStaker;
    masterOfCoin: MasterOfCoin;
    metadataStore: MockLegionMetadataStore;
    mine: AtlasMine;
    magic: TestERC20;
    treasures: TestERC1155;
    legions: TestERC721;
    start: number;
    end: number;
}

export interface Action {
    timestamp: number;
    actions: ActionInfo[];
}

export interface ActionInfo {
    signer: SignerWithAddress;
    amount: BigNumberish;
    action: "deposit" | "withdraw" | "claim";
}

export interface RewardInfo {
    signer: SignerWithAddress;
    expectedReward: BigNumberish;
}
export interface ScenarioInfo {
    actions: Action[];
    rewards: RewardInfo[];
}

/////////////////////////////////////////////////////////////////////////////////
///                                  STAKING                                  ///
/////////////////////////////////////////////////////////////////////////////////

export type StakeParams = [SignerWithAddress, BigNumberish];

export const stakeSingle = async (
    staker: AtlasMineStaker,
    user: SignerWithAddress,
    amount: BigNumberish,
): Promise<ContractTransaction> => {
    return staker.connect(user).deposit(amount);
};

export const stakeMultiple = async (staker: AtlasMineStaker, stakes: StakeParams[]): Promise<ContractTransaction[]> => {
    const promises = stakes.map(s => stakeSingle(staker, ...s));
    return Promise.all(promises);
};

export const stakeSequence = async (staker: AtlasMineStaker, stakes: StakeParams[]): Promise<ContractTransaction> => {
    // Only returns final transaction
    let tx: ContractTransaction;
    for (const s of stakes) {
        tx = await stakeSingle(staker, ...s);
    }

    // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
    return tx!;
};

export const withdrawSingle = async (
    staker: AtlasMineStaker,
    user: SignerWithAddress,
): Promise<ContractTransaction> => {
    return staker.connect(user).withdraw();
};

export const withdrawWithRoundedRewardCheck = async (
    staker: AtlasMineStaker,
    user: SignerWithAddress,
    stakeAmount: BigNumberish,
    expectedReward: BigNumberish,
): Promise<ContractTransaction> => {
    const withdrawTx = await withdrawSingle(staker, user);
    const receipt = await withdrawTx.wait();

    // Cannot use expect matchers because of rounded equal comparison
    const withdrawEvent = receipt.events?.find(e => e.event === "UserWithdraw");

    expect(withdrawEvent).to.not.be.undefined;
    expect(withdrawEvent?.args?.[0]).to.eq(user.address);
    expect(withdrawEvent?.args?.[1]).to.eq(stakeAmount);
    expectRoundedEqual(withdrawEvent?.args?.[2], expectedReward);

    return withdrawTx;
};

export const claimWithRoundedRewardCheck = async (
    staker: AtlasMineStaker,
    user: SignerWithAddress,
    expectedReward: BigNumberish,
): Promise<ContractTransaction> => {
    const claimTx = await claimSingle(staker, user);
    const receipt = await claimTx.wait();

    // Cannot use expect matchers because of rounded equal comparison
    const claimEvent = receipt.events?.find(e => e.event === "UserClaim");

    expect(claimEvent).to.not.be.undefined;
    expect(claimEvent?.args?.[0]).to.eq(user.address);
    expectRoundedEqual(claimEvent?.args?.[1], expectedReward);

    return claimTx;
};

export const claimSingle = async (staker: AtlasMineStaker, user: SignerWithAddress): Promise<ContractTransaction> => {
    return staker.connect(user).claim();
};

/////////////////////////////////////////////////////////////////////////////////
///                                  TIME                                     ///
/////////////////////////////////////////////////////////////////////////////////

export const rollSchedule = async (
    staker: AtlasMineStaker,
    start = Math.floor(Date.now() / 1000),
): Promise<ContractTransaction> => {
    const nextTimestamp = start + ONE_DAY_SEC;
    await setNextBlockTimestamp(nextTimestamp);

    return staker.stakeScheduled();
};

// TODO: Assumes 2-week lock. Make flexible if we test different locks
// Move forward 1.3mm seconds, or approximately 15 days
export const rollLock = async (start = Math.floor(Date.now() / 1000)): Promise<number> => {
    const nextTimestamp = start + 1_300_000;
    await setNextBlockTimestamp(nextTimestamp);

    return nextTimestamp;
};

export const rollToPartialWindow = async (start: number, end: number, ratio: number): Promise<number> => {
    const diff = (end - start) * ratio;
    const timestamp = start + diff;
    await setNextBlockTimestamp(timestamp);

    return timestamp;
};

export const rollTo = async (time: number): Promise<void> => {
    await setNextBlockTimestamp(time);
};

/////////////////////////////////////////////////////////////////////////////////
///                                MATCHERS                                   ///
/////////////////////////////////////////////////////////////////////////////////

export const expectRoundedEqual = (num: BigNumberish, target: BigNumberish): void => {
    num = ethers.BigNumber.from(num);
    target = ethers.BigNumber.from(target);

    // Tolerable precision is 0.01%. Precision is lost in the magic mine in both
    // calculating NFT reward boosts and timing per second
    const precision = 50;

    if (target.eq(0)) {
        expect(num).to.be.lt(precision);
    } else {
        // Expect it to be within 4 0s of precision, less than 1 bp diff
        const lowerBound = target.div(precision).mul(precision - 1);
        const upperBound = target.div(precision).mul(precision + 1);

        expect(num).to.be.gt(lowerBound);
        expect(num).to.be.lt(upperBound);
    }
};

export const expectRoughEqual = (num: BigNumberish, target: BigNumberish): void => {
    num = ethers.BigNumber.from(num);
    target = ethers.BigNumber.from(target);

    // Tolerable precision is 1%. Precision is lost in the magic mine in both
    // calculating NFT reward boosts and timing per second
    const precision = 100;

    if (target.eq(0)) {
        expect(num).to.be.lt(precision);
    } else {
        // Expect it to be within 4 0s of precision, less than 1 bp diff
        const lowerBound = target.div(precision).mul(precision - 1);
        const upperBound = target.div(precision).mul(precision + 1);

        expect(num).to.be.gt(lowerBound);
        expect(num).to.be.lt(upperBound);
    }
};

/////////////////////////////////////////////////////////////////////////////////
///                                SCENARIOS                                  ///
/////////////////////////////////////////////////////////////////////////////////

export const setup5050Scenario = async (ctx: TestContext, rollUntil?: number) => {
    const {
        users: [user1, user2],
        staker,
        start,
    } = ctx;

    const end = rollUntil || start;

    // Stake more than rewards to force a withdraw
    // With 2 stakers, each will earn 7000 MAGIC over lock period
    const amount = ether("20000");
    const txs = await stakeMultiple(staker, [
        [user1, amount],
        [user2, amount],
    ]);

    // Wait for all deposits to finish
    await Promise.all(txs.map(t => t.wait()));

    // Go to start of rewards program
    await rollTo(end);

    // Make a tx to deposit
    const tx = await staker.stakeScheduled();
    await tx.wait();

    const timestamp = await rollLock(end);

    // We now have unlocked coins among two stakers who deposited equal
    // amounts at the same time
    return {
        lastBlockTime: timestamp,
        stakes: {
            [user1.address]: amount,
            [user2.address]: amount,
        },
    };
};

export const setup7525Scenario = async (ctx: TestContext) => {
    const {
        users: [user1, user2],
        staker,
        start,
        end,
    } = ctx;

    // Stake more than rewards to force a withdraw
    // With 2 stakers, each will earn 7000 MAGIC over lock period
    const amount = ether("20000");
    let tx = await stakeSingle(staker, user1, amount);
    await tx.wait();

    // Go to start of rewards program
    await rollTo(start);

    // Make a tx to deposit
    tx = await staker.stakeScheduled();
    await tx.wait();

    // Fast-forward to halfway through the lock time and have other
    // user also make a deposit
    const ts = await rollToPartialWindow(start, end, 0.5);

    tx = await stakeSingle(staker, user2, amount);
    await tx.wait();

    await rollSchedule(staker, ts);

    // Fast-forward to end of program
    // User1 should have 75% of rewards
    // User2 should have 25%
    await rollTo(end);

    // We now have unlocked coins among two stakers who deposited equal
    // amounts at the same time
    return {
        lastBlockTime: end,
        stakes: {
            [user1.address]: amount,
            [user2.address]: amount,
        },
        depositTimes: {
            [user1.address]: start,
            [user2.address]: ts,
        },
    };
};

export const setupAdvancedScenario1 = (ctx: TestContext): ScenarioInfo => {
    // Advanced Scenario 1:
    // (Different stake times, no nft boosts)
    //
    // Staker 1 Deposits N at 0
    // Staker 2 Deposits N/3 at 0.25
    // Staker 3 Deposits 2N/3 at 0.5
    // Staker 4 Deposits 2N at 0.75
    // Average ~2.8N deposited over pool lifetime
    // 200 unit deficit
    //
    //            Staker 1 %        Staker 2 %      Staker 3 %     Staker 4 %
    // At T = 0:    100                 0               0               0
    // At T = 0.25:  75                25               0               0
    // At T = 0.5:   50             16.67           33.33               0
    // At T = 0.75:  25              8.33           16.67              50
    // Totals:      62.5             12.5            12.5             12.5
    // Total Deposits:

    const {
        users: [user1, user2, user3, user4],
        start,
        end,
    } = ctx;

    const baseAmount = ether("100");
    const totalTime = end - start;
    const totalRewardsBase = TOTAL_REWARDS.div(10000);

    const actions: Action[] = [
        {
            timestamp: start - ONE_DAY_SEC - 100,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.25,
            actions: [
                {
                    signer: user2,
                    amount: baseAmount.div(3),
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.5,
            actions: [
                {
                    signer: user3,
                    amount: baseAmount.div(3).mul(2),
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.75,
            actions: [
                {
                    signer: user4,
                    amount: baseAmount.mul(2),
                    action: "deposit",
                },
            ],
        },
    ];

    const rewards: RewardInfo[] = [
        {
            signer: user1,
            expectedReward: totalRewardsBase.mul(6250),
        },
        {
            signer: user2,
            expectedReward: totalRewardsBase.mul(1250),
        },
        {
            signer: user3,
            expectedReward: totalRewardsBase.mul(1250),
        },
        {
            signer: user4,
            expectedReward: totalRewardsBase.mul(1250),
        },
    ];

    return { actions, rewards };
};

export const setupAdvancedScenario2 = (ctx: TestContext): ScenarioInfo => {
    // Advanced Scenario 2:
    // (Different stake times, prestaking and unstaking, no nft boosts)
    //
    // Staker 1 Deposits N at -1000
    // Staker 1 Withdraws N at -500
    // Staker 2 Deposits 3N at 0
    // Staker 3 Deposits N at 0
    // Staker 4 Deposits 9N at 0.25
    // Staker 2 Withdraws 3N at 0.25
    // Staker 1 Deposits 2N At 0.5
    // Staker 2 Deposits 3N at 0.75
    //
    //            Staker 1 %        Staker 2 %      Staker 3 %     Staker 4 %
    // At T = -1000: 100                0               0               0
    // At T = -500:    0                0               0               0
    // At T = 0:       0               75              25               0
    // At T = 0.25:    0                0              10              90
    // At T = 0.5: 16.67                0            8.33              75
    // At T = 0.75:13.33               20            6.67              60
    // Totals:       7.5            23.75            12.5           56.25

    const {
        users: [user1, user2, user3, user4],
        start,
        end,
    } = ctx;

    const baseAmount = ether("100");
    const totalTime = end - start;
    const totalRewardsBase = TOTAL_REWARDS.div(10000);

    const actions: Action[] = [
        {
            timestamp: start - ONE_DAY_SEC - 5_000_000,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start - ONE_DAY_SEC - 100_000,
            actions: [
                {
                    signer: user1,
                    amount: 0,
                    action: "withdraw",
                },
            ],
        },
        {
            timestamp: start - ONE_DAY_SEC - 100,
            actions: [
                {
                    signer: user2,
                    amount: baseAmount.mul(3),
                    action: "deposit",
                },
                {
                    signer: user3,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.25,
            actions: [
                {
                    signer: user4,
                    amount: baseAmount.mul(9),
                    action: "deposit",
                },
                {
                    signer: user2,
                    amount: 0,
                    action: "withdraw",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.5,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount.mul(2),
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.75,
            actions: [
                {
                    signer: user2,
                    amount: baseAmount.mul(3),
                    action: "deposit",
                },
            ],
        },
    ];

    const rewards: RewardInfo[] = [
        {
            signer: user1,
            expectedReward: totalRewardsBase.mul(750),
        },
        {
            signer: user2,
            expectedReward: totalRewardsBase.mul(2375),
        },
        {
            signer: user3,
            expectedReward: totalRewardsBase.mul(1250),
        },
        {
            signer: user4,
            expectedReward: totalRewardsBase.mul(5625),
        },
    ];

    return { actions, rewards };
};

export const setupAdvancedScenario3 = (ctx: TestContext): ScenarioInfo => {
    // Advanced Scenario 3:
    // (Same as scenario 2, with midstream claims)
    //
    // Staker 1 Deposits N at -1000
    // Staker 1 Withdraws N at -500
    // Staker 2 Deposits 3N at 0
    // Staker 3 Deposits N at 0
    // Staker 4 Deposits 9N at 0.25
    // Staker 2 Withdraws 3N at 0.25
    // Staker 1 Deposits 2N At 0.5
    // Staker 4 Claims at 0.5
    // Staker 2 Deposits 3N at 0.75
    // Staker 1 Claims at 0.75

    //
    //            Staker 1 %        Staker 2 %      Staker 3 %     Staker 4 %
    // At T = -1000: 100                0               0               0
    // At T = -500:    0                0               0               0
    // At T = 0:       0               75              25               0
    // At T = 0.25:    0                0              10              90
    // At T = 0.5: 16.67                0            8.33              75
    // At T = 0.75:13.33               20            6.67              60
    // Totals:       7.5            23.75            12.5           56.25

    const {
        users: [user1, user2, user3, user4],
        start,
        end,
    } = ctx;

    const baseAmount = ether("100");
    const totalTime = end - start;
    const totalRewardsBase = TOTAL_REWARDS.div(10000);

    const actions: Action[] = [
        {
            timestamp: start - ONE_DAY_SEC - 5_000_000,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start - ONE_DAY_SEC - 100_000,
            actions: [
                {
                    signer: user1,
                    amount: 0,
                    action: "withdraw",
                },
            ],
        },
        {
            timestamp: start - ONE_DAY_SEC - 100,
            actions: [
                {
                    signer: user2,
                    amount: baseAmount.mul(3),
                    action: "deposit",
                },
                {
                    signer: user3,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.25,
            actions: [
                {
                    signer: user4,
                    amount: baseAmount.mul(9),
                    action: "deposit",
                },
                {
                    signer: user2,
                    amount: 0,
                    action: "withdraw",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.5,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount.mul(2),
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.75,
            actions: [
                {
                    signer: user2,
                    amount: baseAmount.mul(3),
                    action: "deposit",
                },
            ],
        },
    ];

    const rewards: RewardInfo[] = [
        {
            signer: user1,
            expectedReward: totalRewardsBase.mul(750),
        },
        {
            signer: user2,
            expectedReward: totalRewardsBase.mul(2375),
        },
        {
            signer: user3,
            expectedReward: totalRewardsBase.mul(1250),
        },
        {
            signer: user4,
            expectedReward: totalRewardsBase.mul(5625),
        },
    ];

    return { actions, rewards };
};

export const setupAdvancedScenario4 = (ctx: TestContext): ScenarioInfo => {
    // Advanced Scenario :
    // Multiple deposits for same user, midstream claims, with DAO fee of 4%
    //
    // Staker 1 Deposits N at 0
    // Staker 2 Deposits 2N at 0
    // Staker 1 Deposits N at 0.25
    // Staker 3 Deposits 2N at 0.5
    // Staker 2 Withdraws at 0.5
    // Staker 1 Deposits N at 0.5
    // Staker 4 Deposits 3N at 0.75
    // Staker 1 Claims at 0.75
    //
    //            Staker 1 %        Staker 2 %      Staker 3 %     Staker 4 %
    // At T = 0:   33.33            66.67               0               0
    // At T = 0.25:   50               50               0               0
    // At T = 0.5:    60                0              40               0
    // At T = 0.75: 37.5                0              25            37.5
    // Totals:     45.21            29.17           16.25            9.38

    const {
        users: [user1, user2, user3, user4],
        start,
        end,
    } = ctx;

    const baseAmount = ether("100");
    const totalTime = end - start;
    const totalRewardsBase = TOTAL_REWARDS.div(10000);

    const actions: Action[] = [
        {
            timestamp: start - ONE_DAY_SEC - 100,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount,
                    action: "deposit",
                },
                {
                    signer: user2,
                    amount: baseAmount.mul(2),
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.25,
            actions: [
                {
                    signer: user1,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.5,
            actions: [
                {
                    signer: user2,
                    amount: 0,
                    action: "withdraw",
                },
                {
                    signer: user3,
                    amount: baseAmount.mul(2),
                    action: "deposit",
                },
                {
                    signer: user1,
                    amount: baseAmount,
                    action: "deposit",
                },
            ],
        },
        {
            timestamp: start + totalTime * 0.75,
            actions: [
                {
                    signer: user1,
                    amount: 0,
                    action: "claim",
                },
                {
                    signer: user4,
                    amount: baseAmount.mul(3),
                    action: "deposit",
                },
            ],
        },
    ];

    const rewards: RewardInfo[] = [
        {
            signer: user1,
            expectedReward: totalRewardsBase.mul(4521).div(100).mul(96),
        },
        {
            signer: user2,
            expectedReward: totalRewardsBase.mul(2917).div(100).mul(96),
        },
        {
            signer: user3,
            expectedReward: totalRewardsBase.mul(1625).div(100).mul(96),
        },
        {
            signer: user4,
            expectedReward: totalRewardsBase.mul(938).div(100).mul(96),
        },
    ];

    return { actions, rewards };
};

// export const setupAdvancedScenario5 = (ctx: TestContext): ScenarioInfo => {
//     // Advanced Scenario 5:
//     // (Multiple deposits for same user, midstream claims, 2 stakers, one NFT boosted)

// }

export const runScenario = async (ctx: TestContext, actions: Action[]): Promise<{ [user: string]: BigNumberish }> => {
    const { staker, end } = ctx;
    const claims: { [user: string]: BigNumberish } = {};

    // Run through scenario from beginning of program until end
    for (const batch of actions) {
        const { timestamp, actions: batchActions } = batch;

        // Make deposit, then roll to stake
        await rollTo(timestamp);
        let tx: ContractTransaction;

        for (const a of batchActions) {
            const { signer, amount, action } = a;

            if (action === "deposit") {
                tx = await staker.connect(signer).deposit(amount);
            } else if (action === "claim") {
                // No need to roll, just claim - keep track of amount rewarded
                tx = await staker.connect(signer).claim();
                const receipt = await tx.wait();

                const claimEvent = receipt.events?.find(e => e.event === "UserClaim");

                expect(claimEvent).to.not.be.undefined;
                expect(claimEvent?.args?.[0]).to.eq(signer.address);

                const reward = claimEvent?.args?.[1];

                if (claims[signer.address]) {
                    claims[signer.address] = ethers.BigNumber.from(claims[signer.address]).add(reward);
                } else {
                    claims[signer.address] = reward;
                }
            } else if (action === "withdraw") {
                // No need to roll, just claim - keep track of amount rewarded
                tx = await staker.connect(signer).withdraw();
                const receipt = await tx.wait();

                const withdrawEvent = receipt.events?.find(e => e.event === "UserWithdraw");

                expect(withdrawEvent).to.not.be.undefined;
                expect(withdrawEvent?.args?.[0]).to.eq(signer.address);

                const reward = withdrawEvent?.args?.[2];

                if (claims[signer.address]) {
                    claims[signer.address] = ethers.BigNumber.from(claims[signer.address]).add(reward);
                } else {
                    claims[signer.address] = reward;
                }
            }
        }

        await tx!.wait();

        const depositAction = batchActions.find(a => a.action === "deposit");
        if (depositAction) {
            // Now roll again and stake
            await rollTo(timestamp + ONE_DAY_SEC);
            const tx = await staker.stakeScheduled();
            await tx.wait();
        }

        // Actions for timestamp done
    }

    // Now roll to end - all staking should be processed
    await rollTo(end);

    return claims;
};
