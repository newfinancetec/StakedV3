// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./Ownable.sol";
import "./TransferHelper.sol";
import "./SafeMath.sol";
import "./SafeCast.sol";
import "./ECDSA.sol";
import "./IERC20.sol";
import "./ReentrancyGuard.sol";
import "./Address.sol";


import "./ISwapRouter.sol";
import "./IQuoterV2.sol";


import "./IUniswapV3Pool.sol";
import "./IPancakeV3LmPool.sol";
import "./IUniswapV3Factory.sol";

import "./IMasterChefV3.sol";

import "./ICompute.sol";
import "./INonfungiblePositionManager.sol";
import "./IWETH9.sol";


contract StakedV3 is Ownable,ReentrancyGuard {
	using SafeMath for uint256;
	using SafeCast for uint256;
	
	
	address public route;
	address public quotev2;
	address public compute;

	address public factory;
	address public weth;
	address public manage;
	
	// struct Token {
	// 	uint kind;			//1:ETH 2:WETH 3:ERC20
	// 	address token;		//代币合约地址
	// }

	struct pool {
		address token0; 		//质押币种合约地址
		address token1;		//另一种币种合约地址
		address pool;		//pool 合约地址
		address farm;		//farm 地址
		uint24 fee;			//pool手续费
		uint point;			//滑点
		bool inStatus;		//是否开启质押
		bool outStatus;		//是否可以提取
		uint tokenId;		//质押的nft tokenId
		uint wight0;
		uint wight1;
		uint lp0;
		uint lp1;
	}

	// 是否自动进行Farm
	bool private isFarm = true;	
	
	// 滑点最大比率 * 2
	uint private pointMax = 10 ** 8;

	// 提取签名验证地址
	address private signer;
	
	// 禁用的证明
	mapping(bytes => bool) expired;

	// 项目库
	mapping(uint => pool) public pools;

	event VerifyUpdate(address signer);
	event Setting(address route,address quotev2,address compute,address factory,address weth,address manage);
	event InvestToken(uint pid,address user,uint amount,uint investType,uint cycle,uint time);
	event ExtractToken(uint pid,address user,address token,uint amount,uint tradeType,bytes sign,uint time);

	constructor (address _route,address _quotev2,address _compute,address _signer) {
		_setting(_route,_quotev2,_compute);
		_verifySign(_signer);
	}

	// 接收ETH NFT
    receive() external payable {}
    fallback() external payable {}
	function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }


	function _tokenSend(
        address _token,
        uint _amount
    ) private returns (bool result) {
        if(_token == address(0)){
            Address.sendValue(payable(msg.sender),_amount);
            result = true;
        }else{
            IERC20 token = IERC20(_token);
            result = token.transfer(msg.sender,_amount);
        }
    }


	function balanceOf(
		address _token
	) public view returns (uint balance) {
		if(_token == weth) {
			balance = address(this).balance;
		}else {
			IERC20 token = IERC20(_token);
            balance = token.balanceOf(address(this));
		}
	}

	function unWrapped() private {
		IERC20 token = IERC20(weth);
        uint balance = token.balanceOf(address(this));
		if(balance > 0) {
			IWETH9(weth).withdraw(balance);
		}
	}

	function pointHandle(
		uint point,
		uint amount,
		bool isplus
	) private view returns (uint result) {
		uint rate = 1;
		if(isplus) {
			rate = pointMax.add(point);
		}else {
			rate = pointMax.sub(point);
		}
		result = amount.mul(rate).div(pointMax);
	}

	function hashMsg(
		uint id,
		address token,
		uint amount,
		uint deadline
	) private view returns (bytes32 msghash) {
		return	keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(id,block.chainid,msg.sender,token,amount,deadline))
            )
        );
	}


	function abs(
		int x
	) private pure returns (int) {
		return x >= 0 ? x : -x;
	}

	// 余额检查 尝试发放 返回是否发放成功
	function extractAmount(
		address token,
		uint amount
	) private returns (bool) {
		uint balance = balanceOf(token);
		// 平台储量是否足够 足够直接发放
		if(balance >= amount) {
			if(token != weth) {
				require(_tokenSend(token,amount),"Staked::extract fail");
			}else {
				require(_tokenSend(address(0),amount),"Staked::extract fail");
			}
			return true;
		}else {
			return false;
		}
	}

	// 对失效的项目进行激活
	function Reboot(
		uint id,
		uint deadline
	) public onlyOwner {
		
		(bool pass,PoolToken memory tokens) = Challenge(id);
		if(!pass) {
			// 收割收益
			_harvest(id);
			// 移除当前项目Farm的所有流动性
			_remove(id,tokens,deadline);

			// 兑换成质押币种
			_reSwap(id,tokens);
			// 提现NFT
			_withdraw(id);

			// 更新最新币种价格比率
			wightReset(id);

			// 单币种转成两个币种进行Farm
			uint amount0 = lpRate(id);
			(uint amountOut,) = _amountOut(id,pools[id].token0,pools[id].token1,amount0,false);

			Swap(id,pools[id].token0,pools[id].token1,amount0,amountOut,0);
			Mint(id,deadline);
		}
	}
	
	// 提取Token 流动性失效时的处理
	function invalid(
		uint id,
		address token,
		uint amount,
		uint deadline,
		PoolToken memory tokens
	) private {
		// 收割收益
		_harvest(id);
		// 移除当前项目Farm的所有流动性
		_remove(id,tokens,deadline);
		// bytes memory path;
		uint amountOut;
		uint balance;

		// 全部转换为提取币种
		if(tokens.token0 == token) {
			if(tokens.amount0 == 0) {
				(amountOut,balance) = _amountOut(id,tokens.token1,tokens.token0,0,true);
				Swap(id,tokens.token1,tokens.token0,balance,amountOut,0);
			}
		}else {
			if(tokens.amount1 == 0) {
				(amountOut,balance) = _amountOut(id,tokens.token0,tokens.token1,0,true);
				Swap(id,tokens.token0,tokens.token1,balance,amountOut,0);
			}
		}
		// 第二次尝试发放
		bool result = extractAmount(token,amount);
		require(result,"Staked::extraction failed (invalid:Insufficient reserves1)");
		// 提现NFT 以及重置Farm质押
		_withdraw(id);
		// 全部转换为质押币种
		if(pools[id].token0 != token) {
			(amountOut,balance) = _amountOut(id,pools[id].token1,pools[id].token0,0,true);
			Swap(id,pools[id].token1,pools[id].token0,balance,amountOut,0);
		}
		
		// 更新最新币种价格比率
		wightReset(id);

		// 单币种转成两个币种进行Farm
		uint amount0 = lpRate(id);
		(amountOut,) = _amountOut(id,pools[id].token0,pools[id].token1,amount0,false);
		Swap(id,pools[id].token0,pools[id].token1,amount0,amountOut,0);
		Mint(id,deadline);
	}
	
	function wightReset(
		uint id
	) private {
		(uint amountOut,) = _amountOut(id,pools[id].token0,pools[id].token1,10 ** 18,false);
		pools[id].wight0 = 10 ** 18;
		pools[id].wight1 = amountOut;
	}

	function tryRun(
		uint id,
		address token,
		uint amount,
		uint deadline,
		PoolToken memory tokens,
		uint liquidity
	) private returns (bool) {
		
		if(tokens.liquidity > liquidity) {
			tokens.liquidity = uint128(liquidity);
		}else {
			tokens.liquidity = uint128(tokens.liquidity * 9999 / 10000);
		}
		require(tokens.liquidity > 0,"Staked::insufficient liquidity (valid)");
		(tokens.amount0,tokens.amount1) = ICompute(compute).getAmountsForLiquidity(tokens.sqrtPriceX96,tokens.sqrtRatioAX96,tokens.sqrtRatioBX96,tokens.liquidity);
		_remove(id,tokens,deadline);
		// 尝试发放
		bool result = extractAmount(token,amount);
		uint balance;
		if(!result) {
			if(token == tokens.token0) {
				balance = balanceOf(tokens.token1);
				tokens.amount1 = tokens.amount1 > balance ? balance : tokens.amount1;
				Swap(id,tokens.token1,tokens.token0,tokens.amount1,6,0);
			}else {
				balance = balanceOf(tokens.token0);
				tokens.amount0 = tokens.amount0 > balance ? balance : tokens.amount0;
				Swap(id,tokens.token0,tokens.token1,tokens.amount0,6,0);
			}
			// 尝试发放
			result = extractAmount(token,amount);
		}
		return result;
	}

	function valid(
		uint id,
		address token,
		uint amount,
		uint deadline,
		PoolToken memory tokens
	) private {
		uint liquidity;
		uint balance = balanceOf(token);
		uint temp = amount.sub(balance).div(2);
		temp = temp >= 1 ? temp : 1;

		if(token == tokens.token0 && tokens.amount0 > 0) {
			liquidity = tokens.liquidity * temp / tokens.amount0;
		}else if(tokens.amount1 > 0) {
			liquidity = tokens.liquidity * temp / tokens.amount1;
		}
		// 移除上浮2%
		uint upAmount = liquidity * 102 / 100;
		if(upAmount > tokens.liquidity) {
			liquidity = liquidity * 101 / 100;
		}else {
			liquidity = upAmount;
		}
		// 第二三次
		bool result = tryRun(id,token,amount,deadline,tokens,liquidity);

		if(!result) {
			balance = balanceOf(token);
			uint outAmount = amount.sub(balance).mul(102).div(100);
			(,tokens) = Challenge(id);
			liquidity = uint128(liquidity * outAmount / temp);
			// 第四五次
			result = tryRun(id,token,amount,deadline,tokens,liquidity);
		}
		
		require(result,"Staked::final extraction failed");
	}

	function lpExtract(
		uint id,
		address token,
		uint amount,
		uint deadline
	) private {
		require(pools[id].token0 == token || pools[id].token1 == token,"Staked::does not support decompression");
		require(pools[id].tokenId != 0,"Staked::insufficient liquidity (lpExtract)");
		// 第一次尝试发放
		bool result = extractAmount(token,amount);

		if(!result) {

			(bool pass,PoolToken memory tokens) = Challenge(id);
			// 流动性是否失效
			if(pass) {
				valid(id,token,amount,deadline,tokens);
			}else {
				invalid(id,token,amount,deadline,tokens);
			}
			
		}
	}

	function unlpExtract(
		uint amount,
		address token
	) private {
		uint balance = balanceOf(token);
		if(token != weth) {
			require(balance >= amount,"Staked::insufficient funds reserves");
			require(_tokenSend(token,amount),"Staked::profit extract fail");
		}else {
			require(balance >= amount,"Staked::insufficient funds reserves");
			require(_tokenSend(address(0),amount),"Staked::profit extract fail");
		}
	}

	function Extract(
		uint id,
		uint tradeType,
		address token,
		uint amount,
		uint deadline,
		bytes memory signature
	) public nonReentrant {
		require(pools[id].outStatus,"Staked::extract closed");
		require(deadline > block.timestamp,"Staked::transaction lapsed");
		require(!expired[signature],"Staked::certificate expired");

		address prove = ECDSA.recover(hashMsg(id,token,amount,deadline), signature);
		require(signer == prove,"Staked::invalid certificate");	
		expired[signature] = true;

		// 收益是否为构成lp的币种
		if(pools[id].token0 == token) {
			lpExtract(id,token,amount,deadline);
		} else if(pools[id].token1 == token) {
			lpExtract(id,token,amount,deadline);
		} else {
			unlpExtract(amount,token);
		}

		emit ExtractToken(id,msg.sender,token,amount,tradeType,signature,block.timestamp);
	}

	function Convert(
		address tokenIn,
		uint inAmount,
		uint outAmount,
		bytes memory path,
		uint side
	) public onlyOwner {
		_swap(tokenIn,inAmount,outAmount,path,side);
	}


	function pendingReward(
		uint id
	) public view returns (uint256 reward) {
		reward = IMasterChefV3(pools[id].farm).pendingCake(pools[id].tokenId);
	}

	function harvestFarm(
		uint id
	) public onlyOwner {
		_harvest(id);
	}
	function _harvest(
		uint id
	) private {
		IMasterChefV3(pools[id].farm).harvest(pools[id].tokenId,address(this));
	}

	function withdrawNFT(
		uint tokenId
	) public onlyOwner {
		INonfungiblePositionManager(manage).safeTransferFrom(address(this),msg.sender,tokenId);
	}


	function withdrawFarm(
		uint id,
		uint deadline
	) public onlyOwner {
		_harvest(id);
		(,PoolToken memory tokens) = Challenge(id);
		_remove(id,tokens,deadline);
		_withdraw(id);
	}

	function _withdraw(
		uint id
	) private {
		IMasterChefV3(pools[id].farm).withdraw(pools[id].tokenId,address(this));
		// tokenId重置为0
		pools[id].tokenId = 0;
	}

	function Invest(
		uint id,
		uint amount,
		uint quoteAmount,
		uint investType,
		uint cycle,
		uint deadline
	) public payable nonReentrant {
		require(pools[id].inStatus,"Staked::invest project closed");
		require(deadline > block.timestamp,"Staked::transaction lapsed");
		// 质押代币
		if(pools[id].token0 == weth) {
			require(msg.value == amount,"Staked::input eth is not accurate");
		}else {
			TransferHelper.safeTransferFrom(pools[id].token0,msg.sender,address(this),amount);
		}
		uint balance = balanceOf(pools[id].token0);
		uint amount0 = lpRate(id);

		if(isFarm) {
			// 流动性检查
			(bool pass,PoolToken memory tokens) = Challenge(id);
			if(!pass) {
				// 收割收益
				_harvest(id);
				// 移除流动性
				_remove(id,tokens,deadline);
				// 兑换成质押币种
				_reSwap(id,tokens);
				// 提现NFT
				_withdraw(id);
				// 更新最新币种价格比率
				wightReset(id);
			}
			// 代币兑换
			// token0参与兑换的数量 滑点:0.5% (50% + 0.5%) * 合约中所有token0的数量
			balance = balanceOf(pools[id].token0);
			amount0 = lpRate(id);
			// quoteAmount 重新计算估值
			if(!pass) {
				(quoteAmount,) = _amountOut(id,pools[id].token0,pools[id].token1,amount0,false);
			}
			// 兑换token1代币 0:支出固定数量代币 
			Swap(id,pools[id].token0,pools[id].token1,amount0,quoteAmount,0);

			// 添加流动性
			if(pools[id].tokenId == 0) {
				// Mint
				Mint(id,deadline);
			}else {
				// Append
				Append(id,tokens,deadline);
			}
		}
		if(amount > 0) {
			emit InvestToken(id,msg.sender,amount,investType,cycle,block.timestamp);
		}
	}

	struct PoolToken {
		address token0;
		address token1;
		uint amount0;
		uint amount1;
		int24 tickLower;
		int24 tickUpper;
		uint160 sqrtPriceX96;
		uint160 sqrtRatioAX96;
		uint160 sqrtRatioBX96;
		uint128 liquidity;
	}

	// 将无效流动性中的代币都兑换成质押代币
	function _reSwap(
		uint id,
		PoolToken memory tokens
	) private {
		uint balance;
		uint amountOut;
		if(tokens.amount0 != 0) {
			if(tokens.token0 != pools[id].token0) {
				(amountOut,balance) = _amountOut(id,tokens.token0,tokens.token1,0,true);
				Swap(id,tokens.token0,tokens.token1,balance,amountOut,0);
			}
		}else if(tokens.amount1 != 0) {
			if(tokens.token1 == pools[id].token1) {
				(amountOut,balance) = _amountOut(id,tokens.token1,tokens.token0,0,true);
				Swap(id,tokens.token1,tokens.token0,balance,amountOut,0);
			}
		}
	}

	function _amountOut(
		uint id,
		address tokenIn,
		address tokenOut,
		uint amountIn,
		bool all
	) private returns (uint outAmount,uint inAmount) {
		if(all) {
			amountIn = balanceOf(tokenIn);
		}
		bytes memory path = abi.encodePacked(tokenIn,pools[id].fee,tokenOut);
		(outAmount,,,) = IQuoterV2(quotev2).quoteExactInput(path,amountIn);
		inAmount = amountIn;
	}

	function _remove(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		uint min0 = pointHandle(pools[id].point,tokens.amount0,false);
		uint min1 = pointHandle(pools[id].point,tokens.amount1,false);
		if(tokens.liquidity > 0) {
			IMasterChefV3(pools[id].farm).decreaseLiquidity(
				IMasterChefV3.DecreaseLiquidityParams({
					tokenId:pools[id].tokenId,
					liquidity:tokens.liquidity,
					amount0Min:min0,
					amount1Min:min1,
					deadline:deadline
				})
			);
		}
		IMasterChefV3(pools[id].farm).collect(
			IMasterChefV3.CollectParams({
				tokenId:pools[id].tokenId,
				recipient:address(this),
				amount0Max:uint128(0xffffffffffffffffffffffffffffffff),
				amount1Max:uint128(0xffffffffffffffffffffffffffffffff)
			})
		);
		unWrapped();
	}

	function Mint(
		uint id,
		uint deadline
	) private {
		(uint160 sqrtPriceX96,int24 tick,,,,,) = IUniswapV3Pool(pools[id].pool).slot0();
		int24 tickSpacing = IUniswapV3Pool(pools[id].pool).tickSpacing();
		int256 grap = abs(tick * pools[id].point.toInt256() / pointMax.toInt256());
	
		uint160 sqrtRatioAX96 = ICompute(compute).sqrtRatioAtTick(int24((tick - grap) / tickSpacing * tickSpacing));
		uint160 sqrtRatioBX96 = ICompute(compute).sqrtRatioAtTick(int24((tick + grap) / tickSpacing * tickSpacing));

		// 对应正确的币种以及数量
		bool correct = pools[id].token0 < pools[id].token1;
		PoolToken memory tokens;
		if(correct) {
			tokens = PoolToken({
				token0:pools[id].token0,
				token1:pools[id].token1,
				amount0:balanceOf(pools[id].token0),
				amount1:balanceOf(pools[id].token1),
				tickLower:int24((tick - grap) / tickSpacing * tickSpacing),
				tickUpper:int24((tick + grap) / tickSpacing * tickSpacing),
				sqrtPriceX96:sqrtPriceX96,
				sqrtRatioAX96:sqrtRatioAX96,
				sqrtRatioBX96:sqrtRatioBX96,
				liquidity:0
			});
		}else {
			tokens = PoolToken({
				token0:pools[id].token1,
				token1:pools[id].token0,
				amount0:balanceOf(pools[id].token1),
				amount1:balanceOf(pools[id].token0),
				tickLower:int24((tick - grap) / tickSpacing * tickSpacing),
				tickUpper:int24((tick + grap) / tickSpacing * tickSpacing),
				sqrtPriceX96:sqrtPriceX96,
				sqrtRatioAX96:sqrtRatioAX96,
				sqrtRatioBX96:sqrtRatioBX96,
				liquidity:0
			});
		}
		uint128 liquidity = ICompute(compute).getLiquidityForAmounts(sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,tokens.amount0,tokens.amount1);
		(tokens.amount0,tokens.amount1) = ICompute(compute).getAmountsForLiquidity(sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,liquidity);
		_mint(id,tokens,deadline);
	}

	function _mint(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		require(tokens.amount0 > 0,"Staked::Abnormal liquidity");
		require(tokens.amount1 > 0,"Staked::Abnormal liquidity");
		uint ethAmount = 0;
		
		if(tokens.token0 != weth) {
			TransferHelper.safeApprove(tokens.token0,manage,tokens.amount0);
		} else {
			ethAmount = tokens.amount0;
		}
		if(tokens.token1 != weth) {
			TransferHelper.safeApprove(tokens.token1,manage,tokens.amount1);
		} else {
			ethAmount = tokens.amount1;
		}
		uint amount0;
		uint amount1;
		// 添加流动性位置
		(pools[id].tokenId,,amount0,amount1) = INonfungiblePositionManager(manage).mint{ value:ethAmount }(
			INonfungiblePositionManager.MintParams({
				token0:tokens.token0,
				token1:tokens.token1,
				fee:pools[id].fee,
				tickLower:tokens.tickLower,
				tickUpper:tokens.tickUpper,
				amount0Desired:tokens.amount0,
				amount1Desired:tokens.amount1,
				amount0Min:1,
				amount1Min:1,
				recipient:address(this),
				deadline:deadline
			})
		);
		if(tokens.token0 == pools[id].token0) {
			pools[id].lp0 = amount0;
			pools[id].lp1 = amount1;
		}else {
			pools[id].lp0 = amount1;
			pools[id].lp1 = amount0;
		}
		// Farm质押
		INonfungiblePositionManager(manage).safeTransferFrom(address(this),pools[id].farm,pools[id].tokenId);
	}

	function Challenge(
		uint id
	) public view returns (bool result,PoolToken memory tokens) {
		uint amount0;
		uint amount1;
		int24 tickLower;
		int24 tickUpper;
		uint160 sqrtPriceX96;
		uint160 sqrtRatioAX96;
		uint160 sqrtRatioBX96;
		if(pools[id].tokenId == 0) {
			result = true;
		} else {
			IMasterChefV3.UserPositionInfo memory tokenPosition = IMasterChefV3(pools[id].farm).userPositionInfos(pools[id].tokenId);
			tickLower = tokenPosition.tickLower;
			tickUpper = tokenPosition.tickUpper;

			(sqrtPriceX96,,,,,,) = IUniswapV3Pool(pools[id].pool).slot0();
			sqrtRatioAX96 = ICompute(compute).sqrtRatioAtTick(tickLower);
			sqrtRatioBX96 = ICompute(compute).sqrtRatioAtTick(tickUpper);
			
			(amount0,amount1) = ICompute(compute).getAmountsForLiquidity(sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,tokenPosition.liquidity);
			if(amount0 == 0 || amount1 == 0) {
				result = false;
			}else {
				result = true;
			}
			bool correct = pools[id].token0 < pools[id].token1;
			tokens = PoolToken({
				token0:correct ? pools[id].token0 : pools[id].token1,
				token1:correct ? pools[id].token1 : pools[id].token0,
				amount0:amount0,
				amount1:amount1,
				tickLower:tickLower,
				tickUpper:tickUpper,
				sqrtPriceX96:sqrtPriceX96,
				sqrtRatioAX96:sqrtRatioAX96,
				sqrtRatioBX96:sqrtRatioBX96,
				liquidity:tokenPosition.liquidity
			});
		}
	}

	function Append(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		require(pools[id].tokenId != 0,"Staked::no liquidity position");

		uint amount0 = balanceOf(tokens.token0);
		uint amount1 = balanceOf(tokens.token1);

		uint128 liquidity = ICompute(compute).getLiquidityForAmounts(tokens.sqrtPriceX96,tokens.sqrtRatioAX96,tokens.sqrtRatioBX96,amount0,amount1);
		(tokens.amount0,tokens.amount1) = ICompute(compute).getAmountsForLiquidity(tokens.sqrtPriceX96,tokens.sqrtRatioAX96,tokens.sqrtRatioBX96,liquidity);
		_append(id,tokens,deadline);
	} 

	function _append(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		require(tokens.amount0 > 0,"Staked::Abnormal liquidity");
		require(tokens.amount1 > 0,"Staked::Abnormal liquidity");
		uint ethAmount = 0;
		if(tokens.token0 != weth) {
			TransferHelper.safeApprove(tokens.token0,pools[id].farm,tokens.amount0);
		} else {
			ethAmount = tokens.amount0;
		}
		if(tokens.token1 != weth) {
			TransferHelper.safeApprove(tokens.token1,pools[id].farm,tokens.amount1);
		} else {
			ethAmount = tokens.amount1;
		}
		(,uint amount0,uint amount1) = IMasterChefV3(pools[id].farm).increaseLiquidity{ value:ethAmount }(
			IMasterChefV3.IncreaseLiquidityParams({
				tokenId:pools[id].tokenId,
				amount0Desired:tokens.amount0,
				amount1Desired:tokens.amount1,
				amount0Min:1,
				amount1Min:1,
				deadline:deadline
			})
		);
		if(tokens.token0 == pools[id].token0) {
			pools[id].lp0 = amount0;
			pools[id].lp1 = amount1;
		}else {
			pools[id].lp0 = amount1;
			pools[id].lp1 = amount0;
		}
	}
	

	// side 0:支出固定数量代币 1:入账固定数量代币
	function Swap(
		uint id,
		address tokenIn,
		address tokenOut,
		uint inAmount,
		uint outAmount,
		uint side
	) private returns (uint,uint) {
		bytes memory path;
		if(side == 0) {
			path = abi.encodePacked(tokenIn,pools[id].fee,tokenOut);
			outAmount = pointHandle(pools[id].point,outAmount,false);
		}else if(side == 1) {
			path = abi.encodePacked(tokenOut,pools[id].fee,tokenIn);
			inAmount = pointHandle(pools[id].point,inAmount,true);
		}
		if(inAmount > 0 && outAmount > 0) {
			_swap(tokenIn,inAmount,outAmount,path,side);
		}
		return (inAmount,outAmount);
	}
	
	function _swap(
		address tokenIn,
		uint inAmount,
		uint outAmount,
		bytes memory path,
		uint side
	) private {
		uint ethAmount = 0;
		if(tokenIn != weth) {
			TransferHelper.safeApprove(tokenIn,route,inAmount);
		}else {
			ethAmount = inAmount;
		}
		
		if(side == 0) {
			// 进行固定输入的兑换,如果执行失败，重新获取汇率尝试再次执行
			try ISwapRouter(route).exactInput{ value:ethAmount }(
				ISwapRouter.ExactInputParams({
					path:path,
					recipient:address(this),
					amountIn:inAmount,
					amountOutMinimum:outAmount
				})
			) {} catch {
				(outAmount,,,) = IQuoterV2(quotev2).quoteExactInput(path,inAmount);
				ISwapRouter(route).exactInput{ value:ethAmount }(
					ISwapRouter.ExactInputParams({
						path:path,
						recipient:address(this),
						amountIn:inAmount,
						amountOutMinimum:outAmount
					})
				);
			}
		}else if(side == 1) {
			// 进行固定输出的兑换,如果执行失败，重新获取汇率尝试再次执行
			try ISwapRouter(route).exactOutput{ value:ethAmount }(
				ISwapRouter.ExactOutputParams({
					path:path,
					recipient:address(this),
					amountOut:outAmount,
					amountInMaximum:inAmount
				})
			) {} catch {
				(inAmount,,,) = IQuoterV2(quotev2).quoteExactOutput(path,outAmount);
				ISwapRouter(route).exactOutput{ value:ethAmount }(
					ISwapRouter.ExactOutputParams({
						path:path,
						recipient:address(this),
						amountOut:outAmount,
						amountInMaximum:inAmount
					})
				);
			}
		}
		unWrapped();
	}

	function poolCreat(
		uint _id,
		address _token0,
		address _token1,
		uint24 _fee,
		uint _point,
		uint[] memory _level0,
		uint[] memory _level1
	) public onlyOwner nonReentrant {
		require(pools[_id].pool == address(0),"Staked::project existent");
		require(_point < pointMax.div(2),"Staked::invalid slippage");
		require(_token0 != _token1,"Staked::invalid pair");

		address tokenIn = _token0 == address(0) ? weth : _token0;
		address tokenOut = _token1 == address(0) ? weth : _token1;

		address _pool = IUniswapV3Factory(factory).getPool(tokenIn,tokenOut,_fee);
		require(_pool != address(0),"Staked::liquidit pool non-existent");
		address _lmPool = IUniswapV3Pool(_pool).lmPool();
		require(_lmPool != address(0),"Staked::does not support farms");
		address _farm = IPancakeV3LmPool(_lmPool).masterChef();
		require(_farm != address(0),"Staked::not bound to farm");
		pools[_id] = pool({
			token0:tokenIn,
			token1:tokenOut,
			fee:_fee,
			pool:_pool,
			farm:_farm,
			point:_point,
			inStatus:true,
			outStatus:true,
			tokenId:uint(0),
			wight0:_level0[0],
			wight1:_level1[0],
			lp0:_level0[1],
			lp1:_level1[1]
		});
	}

	// 计算质押前 通过价值以及流动性比率 计算参与兑换的金额
	function lpRate(
		uint id
	) public view returns (uint inAmount) {
		uint balance = balanceOf(pools[id].token0);
		uint rate0 = pools[id].lp0.mul(pools[id].wight1);
		rate0 = rate0.div(pools[id].wight0);
		uint rate1 = pools[id].lp1;
		uint total = rate0.add(rate1);
		if(total > 0) {
			inAmount = rate1.mul(balance).div(total);
			if(inAmount == 0) {
				inAmount = balance.div(2);
			}
		}else {
			inAmount = balance.div(2);
		}
	}

	function poolControl(
		uint _id,
		bool _in,
		bool _out,
		uint _point,
		uint[] memory _level0,
		uint[] memory _level1
	) public onlyOwner {
		require(_point < pointMax.div(2),"Staked::invalid slippage");
		pools[_id].inStatus = _in;
		pools[_id].outStatus = _out;
		pools[_id].point = _point;
		require(_level0[0] > 0,"Staked::level0[0] > 0");
		require(_level1[0] > 0,"Staked::level1[0] > 0");
		require(_level0[1] > 0,"Staked::level0[1] > 0");
		require(_level1[1] > 0,"Staked::level1[1] > 0");
		pools[_id].wight0 = _level0[0];
		pools[_id].wight1 = _level1[0];
		pools[_id].lp0 = _level0[1];
		pools[_id].lp1 = _level1[1];
	}

	function poolTokenID(
		uint _id,
		uint _tokenId
	) public onlyOwner {
		// (,,address token0,address token1,uint24 fee,,,,,,,) = INonfungiblePositionManager(manage).positions(_tokenId);
		// address _pool = IUniswapV3Factory(factory).getPool(token0,token1,fee);
		// require(_pool == pools[_id].pool,"Staked::invalid tokenId");
		pools[_id].tokenId = _tokenId;
		// address owner = INonfungiblePositionManager(manage).ownerOf(_tokenId);
		// require(owner == address(this),"Staked::invalid nft");
		INonfungiblePositionManager(manage).safeTransferFrom(address(this),pools[_id].farm,pools[_id].tokenId);
	}

	function setting(
		address _route,
		address _quotev2,
		address _compute
	) public onlyOwner {
		_setting(_route,_quotev2,_compute);
	}

	function _setting(
		address _route,
		address _quotev2,
		address _compute
	) private {
		require(_route != address(0),"Staked::invalid route address");
		require(_quotev2 != address(0),"Staked::invalid quotev2 address");
		require(_compute != address(0),"Staked::invalid compute address");
		route = _route;
		quotev2 = _quotev2;
		compute = _compute;
		factory = ISwapRouter(_route).factory();
		weth = ISwapRouter(_route).WETH9();
		manage = ISwapRouter(_route).positionManager();
		emit Setting(route,quotev2,compute,factory,weth,manage);
	}

	function autoFarm(
		bool _auto
	) public onlyOwner {
		_autoFarm(_auto);
	}

	function _autoFarm(
		bool _auto
	) private {
		isFarm = _auto;
	}

	


	function verifySign(
		address _signer
	) public onlyOwner {
		_verifySign(_signer);
	}

	function _verifySign(
		address _signer
	) private {
		require(_signer != address(0),"Staked::invalid signing address");
		signer = _signer;
		emit VerifyUpdate(_signer);
	}

}
