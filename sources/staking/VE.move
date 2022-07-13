/// The module describing NFTized staking position (Voting Escrow).
/// The staking position could be transfered between accounts, used for voting, etc.
/// Detailed explanation of VE standard: https://curve.readthedocs.io/dao-vecrv.html
module MultiSwap::VE {
    use Std::Signer;

    use AptosFramework::Coin::{Self, Coin};
    use AptosFramework::Table::{Self, Table};
    use AptosFramework::Timestamp;
    #[test_only]
    use AptosFramework::Coin::register_internal;
    #[test_only]
    use AptosFramework::Genesis;

    use MultiSwap::Liquid::LAMM;
    #[test_only]
    use MultiSwap::Liquid;

    friend MultiSwap::Distribution;

    // Errors.

    /// When staking pool already exists.
    const ERR_POOL_EXISTS: u64 = 100;

    /// When wrong account initializing staking pool.
    const ERR_WRONG_INITIALIZER: u64 = 101;

    /// When user tried to stake for time more than 4 years (see `MAX_TIME`).
    const ERR_DURATION_MORE_THAN_MAX_TIME: u64 = 102;

    /// When no key found in Table.
    const ERR_KEY_NOT_FOUND: u64 = 103;

    /// When unstake before unlock time.
    const ERR_EARLY_UNSTAKE: u64 = 104;

    /// When there is still rewards on
    const ERR_NON_ZERO_REWARDS: u64 = 105;

    // Constants.

    /// One week in seconds.
    const WEEK: u64 = 604800;

    /// Max stacking time (~4 years).
    const MAX_TIME: u64 = 4 * 365 * 86400;

    /// Represents a staking history point.
    struct Point has store, drop, copy {
        bias: u64,
        slope: u64,
        ts: u64,
    }

    /// Represents staking pool.
    struct StakingPool has key {
        // ID counter for new VE NFTs.
        token_id_counter: u64,
        // Current history epoch.
        current_epoch: u64,
        // History points: <epoch, point>.
        history_points: Table<u64, Point>,
        // The historical slope changes we should take into account during each new epoch.
        m_slope: Table<u64, u64>,
    }

    /// Represents VE NFT itself.
    /// Can't be dropped or cloned, only stored.
    struct VE_NFT has store {
        // ID of the current NFT.
        token_id: u64,
        // Stake.
        stake: Coin<LAMM>,
        // Time when NFT could be reedemed.
        unlock_time: u64,

        // The current epoch, when last slope/bias change happened.
        epoch: u64,
        // History points: <epoch, point>.
        history_points: Table<u64, Point>,
    }

    // Public functions.

    /// Initialize staking pool.
    /// Can be called only by @StakingPool address.
    /// Should be called first and immidiatelly after deploy.
    public fun initialize(account: &signer) {
        assert!(!exists<StakingPool>(@StakingPool), ERR_POOL_EXISTS);
        assert!(Signer::address_of(account) == @StakingPool, ERR_WRONG_INITIALIZER);

        let point_history = Table::new();
        Table::add(&mut point_history, 0, Point {
            bias: 0,
            slope: 0,
            ts: Timestamp::now_seconds(),
        });

        move_to(account, StakingPool {
            token_id_counter: 0,
            current_epoch: 0,
            history_points: point_history,
            m_slope: Table::new(),
        });
    }

    /// Stake LAMM coins for lock_duration seconds.
    /// - `coins` - LAMM coins to stake.
    /// - `lock_duration` - duration of lock in seconds, can't be more than `MAX_TIME`.
    /// Returns `VE_NFT` object contains staked position and related information.
    public fun stake(coins: Coin<LAMM>, lock_duration: u64): VE_NFT acquires StakingPool {
        let pool = borrow_global_mut<StakingPool>(@StakingPool);

        let now = Timestamp::now_seconds();
        let unlock_time = (now + lock_duration) / WEEK * WEEK;
        assert!((unlock_time - now) <= MAX_TIME, ERR_DURATION_MORE_THAN_MAX_TIME);

        pool.token_id_counter = pool.token_id_counter + 1;

        let coins_value = Coin::value(&coins);
        let u_slope = coins_value / MAX_TIME;
        let u_bias = u_slope * (unlock_time - now);

        let last_point = Table::borrow_mut(&mut pool.history_points, pool.current_epoch);
        last_point.bias = last_point.bias + u_bias;
        last_point.slope = last_point.slope + u_slope;

        update_internal(pool);

        let m_slope = Table::borrow_mut_with_default(&mut pool.m_slope, unlock_time, 0);
        *m_slope = *m_slope + u_slope;

        let u_epoch = 1;
        let user_point_history = Table::new();

        Table::add(&mut user_point_history, u_epoch, Point {
            bias: u_bias,
            slope: u_slope,
            ts: now,
        });

        let nft = VE_NFT {
            token_id: pool.token_id_counter,
            stake: coins,
            unlock_time,
            epoch: u_epoch,
            history_points: user_point_history,
        };

        nft
    }

    /// Unstake NFT and get rewards and staked amount back.
    /// `nft` - `VE_NFT` object to unstake.
    /// `check_rewards` - determine if we should check if `nft` have rewards to earn. If assigned bool and in case `nft`
    /// has rewards to earn would revert with error.
    /// Returns staked `LAMM` coins + rewards.
    public fun unstake(nft: VE_NFT, check_rewards: bool): Coin<LAMM> {
        // probably if we still have bias and slope we should revert, as it means there is still rewards on nft.
        let now = Timestamp::now_seconds();
        assert!(now >= nft.unlock_time, ERR_EARLY_UNSTAKE);

        let point = get_nft_history_point(&nft, nft.epoch);
        assert!(!check_rewards || (point.slope == 0 && point.bias == 0), ERR_NON_ZERO_REWARDS);

        let VE_NFT {
            token_id: _,
            stake,
            unlock_time: _,
            epoch,
            history_points: point_history,
        } = nft;

        let i = 1;
        while (i <= epoch) {
            // currently it's less than 208 iterations
            Table::remove(&mut point_history, i);
            i = i + 1;
        };
        Table::destroy_empty(point_history);

        stake
    }

    /// Get `VE_NFT` supply (staked supply).
    public fun supply(): u64 acquires StakingPool {
        let pool = borrow_global<StakingPool>(@StakingPool);
        let last_point = *Table::borrow(&pool.history_points, pool.current_epoch);

        let now = Timestamp::now_seconds();
        let t_i = last_point.ts / WEEK * WEEK;
        let i = 0;
        while (i < 255) {
            t_i = t_i + WEEK;

            let m_slope = 0;
            if (t_i > now) {
                t_i = now;
            } else {
                m_slope = get_m_slope(pool, t_i);
            };

            last_point.bias = calc_bias(&last_point, (t_i - last_point.ts));

            if (t_i == now) {
                break
            };

            last_point.slope = last_point.slope - m_slope;
            last_point.ts = t_i;

            i = i + 1;
        };

        last_point.bias
    }

    /// Create a new epoch and update historical points.
    public fun update() acquires StakingPool {
        let pool = borrow_global_mut<StakingPool>(@StakingPool);

        update_internal(pool);
    }

    /// Creating a new `Point` filled with zeros.
    public fun zero_point(): Point {
        Point {
            bias: 0,
            slope: 0,
            ts: 0,
        }
    }

    // Internal & friend funcs.

    /// Update the `VE_NFT` with rewards.
    /// Only distribution (friend) contract can call it.
    ///
    /// We could allow to update stake with new LAMM coins if NFT holder wants
    /// yet we really can't at this stage, as history table can become too large
    /// and we wouldn't be able destroy it. Yet i think we can play around it later.
    /// So for now it's friend function and we can't merge two NFTs.
    ///
    /// * `nft` - the `VE_NFT` object to update.
    /// * `coins` - coins that will be added to `nft`, usually it's rewards from staking.
    public(friend) fun update_stake(nft: &mut VE_NFT, coins: Coin<LAMM>) acquires StakingPool {
        let pool = borrow_global_mut<StakingPool>(@StakingPool);

        let coins_value = Coin::value(&coins);

        let old_locked = Coin::value(&nft.stake);
        let new_locked = coins_value + old_locked;

        let locked_end = nft.unlock_time;
        let now = Timestamp::now_seconds();

        let u_old_slope = 0;
        let u_old_bias = 0;

        if (locked_end > now && old_locked > 0) {
            u_old_slope = old_locked / MAX_TIME;
            u_old_bias = u_old_slope * (locked_end - now);
        };

        let u_new_slope = 0;
        let u_new_bias = 0;

        if (locked_end > now && new_locked > 0) {
            u_new_slope = new_locked / MAX_TIME;
            u_new_bias = u_new_slope * (locked_end - now);
        };

        update_internal(pool);

        // probably should be just borrow?
        let last_point = Table::borrow_mut(&mut pool.history_points, pool.current_epoch);
        last_point.slope = last_point.slope + (u_new_slope - u_old_slope);
        last_point.bias = last_point.bias + (u_new_bias - u_old_bias);

        let old_dslope = get_m_slope(pool, locked_end);
        if (old_locked > now) {
            let m_slope = Table::borrow_mut_with_default(&mut pool.m_slope, locked_end, 0);
            *m_slope = old_dslope - u_old_slope + u_new_slope; // maybe: old_dslope - u_old_slope + u_new_slope?
        };

        nft.epoch = nft.epoch + 1;
        let new_point = Point {
            slope: u_new_slope,
            bias: u_new_bias,
            ts: now,
        };

        Table::add(&mut nft.history_points, nft.epoch, new_point);
        Coin::merge(&mut nft.stake, coins);
    }

    /// Filling history with new epochs, always adding at least one epoch and history point.
    /// `pool` - staking pool to update.
    fun update_internal(pool: &mut StakingPool) {
        let last_point = *Table::borrow(&pool.history_points, pool.current_epoch);
        let now = Timestamp::now_seconds();

        let last_checkpoint = last_point.ts;
        let t_i = last_checkpoint / WEEK * WEEK;
        let epoch = pool.current_epoch;

        let i = 0;
        while (i < 255) {
            t_i = t_i + WEEK;

            let m_slope = 0;
            if (t_i > now) {
                t_i = now;
            } else {
                m_slope = get_m_slope(pool, t_i);
            };

            last_point.bias = calc_bias(&last_point, (t_i - last_checkpoint));
            last_point.slope = last_point.slope - m_slope;

            last_checkpoint = t_i;
            last_point.ts = t_i;
            epoch = epoch + 1;

            if (t_i == now) {
                break
            } else {
                Table::add(&mut pool.history_points, epoch, last_point);
            };

            i = i + 1;
        };

        pool.current_epoch = epoch;

        let new_point = Table::borrow_mut_with_default(&mut pool.history_points, pool.current_epoch, zero_point());
        new_point.slope = last_point.slope;
        new_point.bias = last_point.bias;
        new_point.ts = last_point.ts;
    }

    /// Get m_slope value with default value equal zero.
    /// `timestamp` - as m_slope stored by timestamps, we should provide time.
    fun get_m_slope(pool: &StakingPool, timestamp: u64): u64 {
        if (Table::contains(&pool.m_slope, timestamp)) {
            *Table::borrow(&pool.m_slope, timestamp)
        } else {
            0
        }
    }

    // Getters funcs.

    /// Calculates new bias: Math.max(point.bias - point.slope * time_diff, 0);
    /// Bias can't go under zero, so we should check if we can substrate point * slope
    /// from bias or just replace it with zero.
    /// `point` - point to calculate new bias.
    /// `time_diff` - time difference used in math.
    /// Returns new bias value.
    public fun calc_bias(point: &Point, time_diff: u64): u64 {
        let r = point.slope * time_diff;

        if (point.bias < r) {
            0
        } else {
            point.bias - r
        }
    }

    /// Get current epoch.
    public fun get_current_epoch(): u64 acquires StakingPool {
        borrow_global<StakingPool>(@StakingPool).current_epoch
    }

    /// Get history point.
    /// `epoch` - epoch of history point.
    public fun get_history_point(epoch: u64): Point acquires StakingPool {
        let pool = borrow_global<StakingPool>(@StakingPool);

        assert!(Table::contains(&pool.history_points, epoch), ERR_KEY_NOT_FOUND);

        *Table::borrow(&pool.history_points, epoch)
    }

    // VE NFT getters.

    /// Get VE NFT id.
    /// `nft` - reference to `VE_NFT`.
    public fun get_nft_id(nft: &VE_NFT): u64 {
        nft.token_id
    }

    /// Get VE NFT staked value.
    /// `nft` - reference to `VE_NFT`.
    public fun get_nft_staked_value(nft: &VE_NFT): u64 {
        Coin::value(&nft.stake)
    }

    /// Get VE NFT unlock time (timestamp).
    /// `nft` - reference to `VE_NFT`.
    public fun get_nft_unlock_time(nft: &VE_NFT): u64 {
        nft.unlock_time
    }

    /// Get current VE NFT epoch.
    /// `nft` - reference to `VE_NFT`.
    public fun get_nft_epoch(nft: &VE_NFT): u64 {
        nft.epoch
    }

    /// Get VE NFT history point.
    /// `nft` - reference to `VE_NFT`.
    /// `epoch` - epoch of history point.
    public fun get_nft_history_point(nft: &VE_NFT, epoch: u64): Point {
        assert!(Table::contains(&nft.history_points, epoch), ERR_KEY_NOT_FOUND);

        *Table::borrow(&nft.history_points, epoch)
    }

    // Point getters.

    /// Get a time when `point` created.
    public fun get_point_ts(point: &Point): u64 {
        point.ts
    }

    /// Get a bias value of `point`.
    public fun get_point_bias(point: &Point): u64 {
        point.bias
    }

    /// Get a slope value of `point`.
    public fun get_point_slope(point: &Point): u64 {
        point.slope
    }

    // Tests.

    #[test_only]
    struct NFTs has key {
        nfts: Table<u64, VE_NFT>,
    }

    #[test_only]
    fun get_id_counter(): u64 acquires StakingPool {
        borrow_global<StakingPool>(@StakingPool).token_id_counter
    }

    #[test_only]
    fun get_m_slope_for_test(epoch: u64): u64 acquires StakingPool {
        let pool = borrow_global<StakingPool>(@StakingPool);
        get_m_slope(pool, epoch)
    }

    #[test]
    fun test_zero_point() {
        let point = zero_point();
        assert!(point.slope == 0, 0);
        assert!(point.bias == 0, 1);
        assert!(point.ts == 0, 2);
    }

    #[test]
    fun test_reduce_bias() {
        let point = Point {
            bias: 32,
            slope: 7,
            ts: 0,
        };

        let new_bias = calc_bias(&point, 5);
        assert!(new_bias == 0, 0);

        let new_bias = calc_bias(&point, 1);
        assert!(new_bias == 25, 1);
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap)]
    fun test_initialize(core: signer, staking_admin: signer, multi_swap: signer) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);

        initialize(&staking_admin);

        let stacker_admin_addr = Signer::address_of(&staking_admin);
        let pool = borrow_global<StakingPool>(stacker_admin_addr);

        assert!(pool.current_epoch == 0, 0);
        assert!(pool.token_id_counter == 0, 1);
        assert!(Table::length(&pool.m_slope) == 0, 2);
        assert!(Table::length(&pool.history_points) == 1, 3);

        let point = Table::borrow(&pool.history_points, 0);
        assert!(point.ts == Timestamp::now_seconds(), 4);
        assert!(point.slope == 0, 5);
        assert!(point.bias == 0, 6);

        assert!(get_current_epoch() == 0, 7);
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap)]
    #[expected_failure(abort_code = 100)]
    fun test_initialize_fail(core: signer, staking_admin: signer, multi_swap: signer) {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);

        initialize(&staking_admin);
        initialize(&staking_admin);
    }

    #[test(core = @CoreResources, multi_swap = @MultiSwap)]
    #[expected_failure(abort_code = 101)]
    fun test_initialize_wrong_account(core: signer, multi_swap: signer) {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);

        initialize(&multi_swap);
    }

    #[test(core = @CoreResources, multi_swap = @MultiSwap, staker = @TestStaker)]
    public fun test_nft_getters(core: signer, multi_swap: signer, staker: signer) {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);

        let to_mint_val = 10000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let now = Timestamp::now_seconds();

        let history_points = Table::new();
        let epoch = 523;
        Table::add(&mut history_points, epoch, Point {
            bias: 50,
            slope: 250,
            ts: now,
        });

        let nft = VE_NFT {
            token_id: 100,
            stake: to_stake,
            unlock_time: Timestamp::now_seconds(),
            epoch,
            history_points,
        };

        assert!(get_nft_id(&nft) == 100, 0);
        assert!(get_nft_staked_value(&nft) == to_stake_val, 1);
        assert!(get_nft_unlock_time(&nft) == now, 2);
        assert!(get_nft_epoch(&nft) == epoch, 3);

        let point = get_nft_history_point(&nft, epoch);

        assert!(point.bias == 50, 4);
        assert!(point.slope == 250, 5);
        assert!(point.ts == now, 6);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft.token_id, nft);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staker = @TestStaker)]
    #[expected_failure(abort_code = 103)]
    fun test_get_nft_history_point_fail(core: signer, staker: signer) {
        Timestamp::set_time_has_started_for_testing(&core);

        let nft = VE_NFT {
            token_id: 1,
            stake: Coin::zero(),
            unlock_time: Timestamp::now_seconds(),
            epoch: 0,
            history_points: Table::new(),
        };

        let _ = get_nft_history_point(&nft, 100);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft.token_id, nft);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    fun test_stake(core: signer, staking_admin: signer, multi_swap: signer, staker: signer) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let now = Timestamp::now_seconds();
        let until = (now + WEEK) / WEEK * WEEK;

        let nft = stake(to_stake, WEEK);
        assert!(nft.token_id == 1, 0);
        assert!(nft.unlock_time == until, 1);

        let nft_point = get_nft_history_point(&nft, nft.epoch);
        assert!(Table::length(&nft.history_points) == 1, 2);
        assert!(nft_point.slope == (to_stake_val / MAX_TIME), 3);
        assert!(nft_point.bias == (nft_point.slope * (until - now)), 4);
        assert!(nft_point.ts == now, 5);

        assert!(get_current_epoch() == 1, 6);
        assert!(get_id_counter() == 1, 7);

        let point = get_history_point(get_current_epoch());
        assert!(point.bias == nft_point.bias, 8);
        assert!(point.slope == nft_point.slope, 9);
        assert!(point.ts == now, 10);

        let m_slope = get_m_slope_for_test(until);
        assert!(m_slope == nft_point.slope, 11);

        to_stake_val = 100000000;
        to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let nft_2 = stake(to_stake, WEEK * 208);
        assert!(get_current_epoch() == 2, 12);
        assert!(get_id_counter() == 2, 13);

        until = (now + WEEK * 208) / WEEK * WEEK;
        let nft_point2 = get_nft_history_point(&nft_2, nft_2.epoch);
        assert!(Table::length(&nft.history_points) == 1, 14);
        assert!(nft_point2.slope == (to_stake_val / MAX_TIME), 15);
        assert!(nft_point2.bias == (nft_point2.slope * (until - now)), 16);
        assert!(nft_point2.ts == now, 17);

        let point2 = get_history_point(get_current_epoch());
        assert!(point2.bias == (nft_point.bias + nft_point2.bias), 18);
        assert!(point2.slope == (nft_point.slope + nft_point2.slope), 19);
        assert!(point2.ts == now, 20);

        let m_slope = get_m_slope_for_test(until);
        assert!(m_slope == nft_point2.slope, 21);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft.token_id, nft);
        Table::add(&mut nfts, nft_2.token_id, nft_2);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    #[expected_failure(abort_code = 102)]
    fun test_stake_fails(core: signer, staking_admin: signer, multi_swap: signer, staker: signer) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let nft = stake(to_stake, WEEK * 209);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft.token_id, nft);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    fun test_update(core: signer, staking_admin: signer, multi_swap: signer, staker: signer) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        update();

        assert!(get_current_epoch() == 1, 0);
        let now = Timestamp::now_seconds();
        let point = get_history_point(get_current_epoch());

        assert!(point.slope == 0, 1);
        assert!(point.bias == 0, 2);
        assert!(point.ts == now, 3);

        // Let's move time and check how history changes.
        now = (Timestamp::now_seconds() + WEEK);
        Timestamp::update_global_time_for_test(now * 1000000);

        update();

        assert!(get_current_epoch() == 2, 4);
        point = get_history_point(get_current_epoch());
        assert!(point.slope == 0, 5);
        assert!(point.bias == 0, 6);
        assert!(point.ts == now, 7);

        // Let's stake and see how history changed.
        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val_1 = 1000000000;
        let to_stake_1 = Coin::withdraw<LAMM>(&staker, to_stake_val_1);
        let dur_1 = WEEK;
        let nft_1 = stake(to_stake_1, dur_1);
        let until_1 = now + dur_1;

        assert!(get_current_epoch() == 3, 8);
        point = get_history_point(get_current_epoch());
        assert!(point.slope == to_stake_val_1 / MAX_TIME, 9);
        assert!(point.bias == point.slope * (until_1 - now), 10);
        assert!(point.ts == now, 11);
        assert!(get_m_slope_for_test(until_1) == point.slope, 12);

        update();

        // Let's check nothing changed.
        assert!(get_current_epoch() == 4, 13);
        let point_1 = get_history_point(get_current_epoch());
        assert!(point_1.slope == to_stake_val_1 / MAX_TIME, 14);
        assert!(point_1.bias == point_1.slope * (until_1 - now), 15);
        assert!(point_1.ts == now, 16);

        // Let's stake again.
        let to_stake_val_2 = 5000000000;
        let to_stake_2 = Coin::withdraw<LAMM>(&staker, to_stake_val_2);
        let dur_2 = WEEK * 208;
        let nft_2 = stake(to_stake_2, dur_2);
        let until_2 = now + dur_2;

        let bias_sum = get_nft_history_point(&nft_1, 1).bias + get_nft_history_point(&nft_2, 1).bias;

        assert!(get_current_epoch() == 5, 17);
        let point_2 = get_history_point(get_current_epoch());

        assert!(point_2.slope == point_1.slope + (to_stake_val_2 / MAX_TIME), 18);
        assert!(point_2.bias == point_1.bias + ((to_stake_val_2 / MAX_TIME) * (until_2 - now)), 19);
        assert!(point_2.bias == bias_sum, 20);

        // Let's move time to half of week and check history.
        now = Timestamp::now_seconds() + WEEK / 2;
        Timestamp::update_global_time_for_test(now * 1000000);
        update();

        assert!(get_current_epoch() == 6, 21);
        let point_3 = get_history_point(get_current_epoch());
        // Slope is not changed yet.
        assert!(point_3.slope == point_2.slope, 22);
        assert!(point_3.bias == point_2.bias - (point_2.slope * (now - point_2.ts)), 23);
        assert!(point_3.ts == now, 24);

        // Let's expire one stake and see how points changed.
        now = Timestamp::now_seconds() + WEEK;
        Timestamp::update_global_time_for_test(now * 1000000);
        update();

        assert!(get_current_epoch() == 8, 25); // Increased on 2, because week passed.
        let point_4 = get_history_point(get_current_epoch());
        assert!(point_4.slope == (point_3.slope - get_m_slope_for_test(until_1)), 26);

        // As we had already epoch on middle of the week, so we should calculate middle of the week
        // with old slope and another part of week with new slope.
        let new_slope = point_3.slope - get_m_slope_for_test(until_1);
        let should_be_bias = point_3.bias - (point_3.slope * (WEEK / 2));
        should_be_bias = should_be_bias - (new_slope * (WEEK / 2));
        assert!(point_4.bias == should_be_bias, 27);

        // Let's stake again for half of week.
        let to_stake_val_3 = 500000000;
        let to_stake_3 = Coin::withdraw<LAMM>(&staker, to_stake_val_3);
        let dur_3 = WEEK / 2;
        let nft_3 = stake(to_stake_3, dur_3);

        // Let's expire everything and see how points changed.
        now = Timestamp::now_seconds() + WEEK * 208;
        Timestamp::update_global_time_for_test(now * 1000000);
        update();

        let point = get_history_point(get_current_epoch());
        assert!(point.bias == 0, 28);
        assert!(point.slope == 0, 29);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft_1.token_id, nft_1);
        Table::add(&mut nfts, nft_2.token_id, nft_2);
        Table::add(&mut nfts, nft_3.token_id, nft_3);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    fun test_supply(core: signer, staking_admin: signer, multi_swap: signer, staker: signer)  acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let supply = supply();
        assert!(supply == 0, 0);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val_1 = 1000000000;
        let to_stake_1 = Coin::withdraw<LAMM>(&staker, to_stake_val_1);
        let dur_1 = 208 * WEEK;
        let nft_1 = stake(to_stake_1, dur_1);

        let expected_supply = (to_stake_val_1 / MAX_TIME) * dur_1;

        supply = supply();
        assert!(supply == expected_supply, 1);

        // 1 week passed.
        let now = Timestamp::now_seconds() + WEEK;
        Timestamp::update_global_time_for_test(now * 1000000);

        expected_supply = (to_stake_val_1 / MAX_TIME) * (dur_1 - WEEK);
        supply = supply();
        assert!(supply == expected_supply, 2);

        // 104 weeks passed.
        now = Timestamp::now_seconds() + WEEK * 103;
        Timestamp::update_global_time_for_test(now * 1000000);

        expected_supply = (to_stake_val_1 / MAX_TIME) * (dur_1 - (WEEK * 104));
        supply = supply();
        assert!(supply == expected_supply, 3);

        // 208 weeks passed.
        now = Timestamp::now_seconds() + WEEK * 104;
        Timestamp::update_global_time_for_test(now * 1000000);
        // Nothing staked.
        assert!(supply() == 0, 4);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft_1.token_id, nft_1);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    fun test_update_stake(core: signer, staking_admin: signer, multi_swap: signer, staker: signer) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let now = Timestamp::now_seconds();
        let to_stake_val = 1000000000;
        let dist = WEEK * 208;
        let until = Timestamp::now_seconds() + dist;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let rewards_val = 256000000;
        let rewards = Coin::withdraw<LAMM>(&staker, rewards_val);

        let nft = stake(to_stake, dist);
        let token_id = nft.token_id;

        let slope = to_stake_val / MAX_TIME;
        let bias = slope * (until - now);

        let nft_point = get_nft_history_point(&nft, 1);
        assert!(nft_point.slope == slope, 0);
        assert!(nft_point.bias == bias, 1);

        // Move time on one week and update stake.
        now = Timestamp::now_seconds() + WEEK;
        Timestamp::update_global_time_for_test(now * 1000000);
        update_stake(&mut nft, rewards);

        assert!(nft.epoch == 2, 2);
        assert!(Coin::value(&nft.stake) == to_stake_val + rewards_val, 3);
        assert!(nft.token_id == token_id, 4);
        assert!(nft.unlock_time == until, 5);

        let new_slope = (to_stake_val + rewards_val) / MAX_TIME;
        let new_bias = new_slope * (until - now);

        let nft_point = get_nft_history_point(&nft, 2);

        assert!(nft_point.bias == new_bias, 6);
        assert!(nft_point.slope == new_slope, 7);
        assert!(nft_point.ts == now, 8);

        assert!(new_slope == get_m_slope_for_test(until), 9);

        let point = get_history_point(get_current_epoch());

        let old_bias = slope * (until - now);
        assert!(point.slope == slope + (new_slope - slope), 10);
        assert!(point.bias == old_bias + (new_bias - old_bias), 11);
        assert!(point.ts == now, 12);

        // Move to 208 weeks and check update.
        now = Timestamp::now_seconds() + WEEK * 208;
        Timestamp::update_global_time_for_test(now * 1000000);

        rewards = Coin::withdraw<LAMM>(&staker, rewards_val);
        update_stake(&mut nft, rewards);

        nft_point = get_nft_history_point(&nft, 3);
        assert!(nft_point.bias == 0, 14);
        assert!(nft_point.slope == 0, 15);
        assert!(nft_point.ts == now, 16);

        point = get_history_point(get_current_epoch());
        assert!(point.slope == 0, 17);
        assert!(point.bias == 0, 18);
        assert!(point.ts == now, 19);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft.token_id, nft);

        move_to(&staker, NFTs {
            nfts
        });
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    fun test_unstake(core: signer, staking_admin: signer, multi_swap: signer, staker: signer) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let dist = WEEK;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let nft = stake(to_stake, dist);

        let now = Timestamp::now_seconds() + WEEK;
        Timestamp::update_global_time_for_test(now * 1000000);

        let unstaked = unstake(nft, false);
        assert!(Coin::value(&unstaked) == to_stake_val, 0);

        Coin::deposit(Signer::address_of(&staker), unstaked);

        to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);
        nft = stake(to_stake, dist);

        let reward_val = 256000000;
        let reward = Coin::withdraw<LAMM>(&staker, reward_val);

        now = Timestamp::now_seconds() + WEEK;
        Timestamp::update_global_time_for_test(now * 1000000);
        update_stake(&mut nft, reward);

        unstaked = unstake(nft, true);
        assert!(Coin::value(&unstaked) == (to_stake_val + reward_val), 1);
        Coin::deposit(Signer::address_of(&staker), unstaked);
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    #[expected_failure(abort_code = 104)]
    fun test_unstake_fail_early(
        core: signer,
        staking_admin: signer,
        multi_swap: signer,
        staker: signer
    ) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let dist = WEEK;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let nft = stake(to_stake, dist);
        let unstaked = unstake(nft, false);

        Coin::deposit(Signer::address_of(&staker), unstaked);
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    #[expected_failure(abort_code = 105)]
    fun test_unstake_fail_has_rewards(
        core: signer,
        staking_admin: signer,
        multi_swap: signer,
        staker: signer
    ) acquires StakingPool {
        Genesis::setup(&core);
        Liquid::initialize(&multi_swap);
        initialize(&staking_admin);

        let to_mint_val = 20000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let dist = WEEK;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let nft = stake(to_stake, dist);

        let now = Timestamp::now_seconds() + WEEK;
        Timestamp::update_global_time_for_test(now * 1000000);

        let unstaked = unstake(nft, true);

        Coin::deposit(Signer::address_of(&staker), unstaked);
    }

    #[test(core = @CoreResources, staking_admin = @StakingPool, multi_swap = @MultiSwap, staker = @TestStaker)]
    fun end_to_end(core: signer, staking_admin: signer, multi_swap: signer, staker: signer) acquires StakingPool {
        Genesis::setup(&core);

        Liquid::initialize(&multi_swap);

        initialize(&staking_admin);

        let current_epoch = get_current_epoch();
        assert!(current_epoch == 0, 0);

        let point = get_history_point(current_epoch);
        assert!(point.ts == Timestamp::now_seconds(), 1);
        assert!(point.bias == 0, 2);
        assert!(point.slope == 0, 3);

        let to_mint_val = 10000000000;
        register_internal<LAMM>(&staker);
        Liquid::mint_internal(&multi_swap, Signer::address_of(&staker), to_mint_val);

        let to_stake_val = 1000000000;
        let to_stake = Coin::withdraw<LAMM>(&staker, to_stake_val);

        let nft = stake(to_stake, WEEK);

        let now = Timestamp::now_seconds();
        let until = (now + WEEK) / WEEK * WEEK;

        let nft_point = get_nft_history_point(&nft, nft.epoch);
        assert!(nft_point.slope == (to_stake_val / MAX_TIME), 4);
        assert!(nft_point.bias == (nft_point.slope * (until - now)), 5);

        current_epoch = get_current_epoch();
        assert!(current_epoch == 1, 6);

        let new_time = (now + WEEK) * 1000000;
        Timestamp::update_global_time_for_test(new_time);
        update();
        current_epoch = get_current_epoch();
        assert!(current_epoch == 2, 7);
        point = get_history_point(current_epoch);
        assert!(point.bias == 0, 8);
        assert!(point.slope == 0, 9);
        assert!(point.ts == WEEK, 10);

        let nfts = Table::new<u64, VE_NFT>();
        Table::add(&mut nfts, nft.token_id, nft);

        move_to(&staker, NFTs {
            nfts
        });
    }
}
