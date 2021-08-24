// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

library Math {
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

library PoolAddress {
    bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    
    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }
    
    function computeAddress(address factory, PoolKey memory key) internal pure returns (address pool) {
        require(key.token0 < key.token1);
        pool = address(
            uint160(uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        factory,
                        keccak256(abi.encode(key.token0, key.token1, key.fee)),
                        POOL_INIT_CODE_HASH
                    )
                )
            )
        ));
    }
}

interface erc20 {
    function transfer(address recipient, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
}

interface PositionManagerV3 {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function safeTransferFrom(address from, address to, uint tokenId) external;
    
    function ownerOf(uint tokenId) external view returns (address);
    function transferFrom(address from, address to, uint tokenId) external;
}

interface UniV3 {
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        );
    function liquidity() external view returns (uint128);
}

contract StakingRewardsV3 {
    
    address immutable public reward;
    address immutable public pool;
    
    address constant factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    PositionManagerV3 constant nftManager = PositionManagerV3(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    uint constant DURATION = 7 days;
    
    uint rewardRate;
    uint periodFinish;
    uint lastUpdateTime;
    uint rewardPerSecondStored;
    uint totalSecondsClaimed;
    
    mapping(uint => uint) public tokenRewardPerSecondPaid;
    mapping(uint => uint) public rewards;
    
    struct time {
        uint32 timestamp;
        uint160 secondsPerLiquidityInside;
    }
    
    mapping(uint => time) public elapsed;
    mapping(uint => address) public owners;
    mapping(address => mapping(uint => bool)) public tokenExists;
    mapping(address => uint[]) public tokenIds;
    
    constructor(address _reward, address _pool) {
        reward = _reward;
        pool = _pool;
    }
    
    function lastTimeRewardApplicable() public view returns (uint) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerSecond() public view returns (uint) {
        return rewardPerSecondStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate);
    }

    function earned(uint tokenId) public view returns (uint claimable, uint160 secondsPerLiquidityInside, uint secondsInside) {
        uint _reward = rewardPerSecond() - tokenRewardPerSecondPaid[tokenId];
            
        time memory _elapsed = elapsed[tokenId];
        secondsPerLiquidityInside = _getSecondsInside(tokenId);
        uint _liquidity = _getLiquidity(tokenId);
        uint _maxSecondsPerLiquidityInside = (lastUpdateTime - _elapsed.timestamp) * _liquidity / UniV3(pool).liquidity();
        secondsInside = Math.min((secondsPerLiquidityInside - _elapsed.secondsPerLiquidityInside) * _liquidity, _maxSecondsPerLiquidityInside);
        claimable = (_reward * secondsInside) + rewards[tokenId];
    }

    function getRewardForDuration() external view returns (uint) {
        return rewardRate * DURATION;
    }

    function deposit(uint tokenId) external update(tokenId) {
        (,,address token0, address token1,uint24 fee,int24 tickLower,int24 tickUpper,uint128 _liquidity,,,,) = nftManager.positions(tokenId);
        address _pool = PoolAddress.computeAddress(factory,PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee}));
        (,uint160 _secondsPerLiquidityInside,) = UniV3(pool).snapshotCumulativesInside(tickLower, tickUpper);

        require(pool == _pool);
        require(_liquidity > 0);
        
        elapsed[tokenId] = time(uint32(lastTimeRewardApplicable()), _secondsPerLiquidityInside);
        
        nftManager.transferFrom(msg.sender, address(this), tokenId);
        owners[tokenId] = msg.sender;
        
        if (!tokenExists[msg.sender][tokenId]) {
            tokenExists[msg.sender][tokenId] = true;
            tokenIds[msg.sender].push(tokenId);
        }
    }

    function withdraw(uint tokenId) public update(tokenId) {
        require(owners[tokenId] == msg.sender);
        owners[tokenId] = address(0);
        nftManager.safeTransferFrom(address(this), msg.sender, tokenId);
    }
    
    function getRewards() external {
        uint[] memory _tokens = tokenIds[msg.sender];
        for (uint i = 0; i < _tokens.length; i++) {
            getReward(_tokens[i]);
        }
    }

    function getReward(uint tokenId) public update(tokenId) {
        uint _reward = rewards[tokenId];
        if (_reward > 0) {
            rewards[tokenId] = 0;
            _safeTransfer(reward, _getRecipient(tokenId), _reward);
        }
    }
    
    function _getRecipient(uint tokenId) internal view returns (address) {
        if (owners[tokenId] != address(0)) {
            return owners[tokenId];
        } else {
            return nftManager.ownerOf(tokenId);
        }
    }
    
    function exit() external {
        uint[] memory _tokens = tokenIds[msg.sender];
        for (uint i = 0; i < _tokens.length; i++) {
            if (nftManager.ownerOf(_tokens[i]) == address(this)) {
                withdraw(_tokens[i]);
            }
            getReward(_tokens[i]);
        }
    }

    function exit(uint tokenId) public {
        withdraw(tokenId);
        getReward(tokenId);
    }
    
    function notify(uint amount) external update(0) {
        _safeTransferFrom(reward, msg.sender, address(this), amount);
        amount += rewardRate * (DURATION - totalSecondsClaimed);
        totalSecondsClaimed = 0;
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / DURATION;
        } else {
            uint _remaining = periodFinish - block.timestamp;
            uint _leftover = _remaining * rewardRate;
            rewardRate = (amount + _leftover) / DURATION;
        }
        
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
    }

    modifier update(uint tokenId) {
        rewardPerSecondStored = rewardPerSecond();
        lastUpdateTime = lastTimeRewardApplicable();
        if (tokenId != 0) {
            (uint _reward, uint160 _secondsPerLiquidityInside, uint _secondsInside) = earned(tokenId);
            tokenRewardPerSecondPaid[tokenId] = rewardPerSecondStored;
            rewards[tokenId] = _reward;
            totalSecondsClaimed += _secondsInside;
            
            if (elapsed[tokenId].timestamp < lastUpdateTime) {
                elapsed[tokenId] = time(uint32(lastUpdateTime), _secondsPerLiquidityInside);
            }
        }
        _;
    }
    
    function _getLiquidity(uint tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,,liquidity,,,,) = nftManager.positions(tokenId);
    }
    
    function _getSecondsInside(uint256 tokenId) internal view returns (uint160 secondsPerLiquidityInside) {
        (,,,,,int24 tickLower,int24 tickUpper,,,,,) = nftManager.positions(tokenId);
        (,secondsPerLiquidityInside,) = UniV3(pool).snapshotCumulativesInside(tickLower, tickUpper);
    }
    
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
    
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}