// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

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
}

contract StakingRewardsV3 {
    
    address immutable public reward;
    address immutable public pool;
    address constant factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    PositionManagerV3 constant nftManager = PositionManagerV3(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    
    uint constant DURATION = 7 days;
    uint constant PRECISION = 10 ** 18;
    
    uint rewardRate;
    uint periodFinish;
    uint lastUpdateTime;
    uint rewardPerTokenStored;
    
    uint unclaimed;
    
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    uint public totalSupply;
    mapping(address => uint) public balanceOf;
    
    struct time {
        uint128 timestamp;
        uint128 secondsInside;
    }
    
    mapping(address => time) public elapsed;
    mapping(uint => address) public owners;
    mapping(address => mapping(uint => bool)) public tokenExists;
    mapping(address => uint[]) public tokenIds;
    
    constructor(address _reward, address _pool) {
        reward = _reward;
        pool = _pool;
    }

    function lastTimeRewardApplicable() public view returns (uint) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION / totalSupply);
    }

    function earned(address account) public view returns (uint) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION);
    }

    function getRewardForDuration() external view returns (uint) {
        return rewardRate * DURATION;
    }

    function deposit(uint tokenId) external update(tokenId) {
        (,,address token0, address token1,uint24 fee,int24 tickLower,int24 tickUpper,uint128 _liquidity,,,,) = nftManager.positions(tokenId);
        address _pool = PoolAddress.computeAddress(factory,PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee}));
        (,,uint32 _secondsInside) = UniV3(pool).snapshotCumulativesInside(tickLower, tickUpper);

        require(pool == _pool);
        require(_liquidity > 0);
        
        elapsed[msg.sender] = time(uint128(block.timestamp), _secondsInside);
        
        totalSupply += _liquidity;
        balanceOf[msg.sender] += _liquidity;
        
        nftManager.safeTransferFrom(msg.sender, address(this), tokenId);
        owners[tokenId] = msg.sender;
        
        if (!tokenExists[msg.sender][tokenId]) {
            tokenExists[msg.sender][tokenId] = true;
            tokenIds[msg.sender].push(tokenId);
        }
    }

    function withdraw(uint tokenId) public update(tokenId) {
        require(owners[tokenId] == msg.sender);
        uint128 _liquidity = _getLiquidity(tokenId);
        
        totalSupply -= _liquidity;
        balanceOf[msg.sender] -= _liquidity;
        
        nftManager.safeTransferFrom(address(this), msg.sender, tokenId);
        owners[tokenId] = address(0);
    }
    
    function getRewards() external {
        uint[] memory _tokens = tokenIds[msg.sender];
        for (uint i = 0; i < _tokens.length; i++) {
            if (nftManager.ownerOf(_tokens[i]) == address(this)) {
                getReward(_tokens[i]);
            }
        }
    }

    function getReward(uint tokenId) public update(tokenId) {
        uint _reward = rewards[msg.sender];
        if (_reward > 0) {
            rewards[msg.sender] = 0;
            _safeTransfer(reward, msg.sender, _reward);
        }
    }
    
    function exit() external {
        uint[] memory _tokens = tokenIds[msg.sender];
        for (uint i = 0; i < _tokens.length; i++) {
            if (nftManager.ownerOf(_tokens[i]) == address(this)) {
                exit(_tokens[i]);
            }
        }
    }

    function exit(uint tokenId) public {
        withdraw(tokenId);
        getReward(tokenId);
    }
    
    function notify(uint amount) external update(0) {
        _safeTransferFrom(reward, msg.sender, address(this), amount);
        amount += unclaimed;
        unclaimed = 0;
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
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        address account = owners[tokenId];
        if (account != address(0)) {
            uint _reward = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
            
            time memory _elapsed = elapsed[account];
            uint32 secondsInside = _getSecondsInside(tokenId);
            
            uint _earned = _reward * (secondsInside - _elapsed.secondsInside) / (block.timestamp - _elapsed.timestamp);
            rewards[account] += _earned;
            unclaimed += (_reward - _earned);
            
            elapsed[msg.sender] = time(uint128(block.timestamp), secondsInside);
        }
        _;
    }
    
    function _getLiquidity(uint tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,,liquidity,,,,) = nftManager.positions(tokenId);
    }
    
    function _getSecondsInside(uint256 tokenId) internal view returns (uint32 secondsInside) {
        (,,,,,int24 tickLower,int24 tickUpper,,,,,) = nftManager.positions(tokenId);
        (,,secondsInside) = UniV3(pool).snapshotCumulativesInside(tickLower, tickUpper);
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