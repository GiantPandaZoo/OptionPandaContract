Option Panda is a decentralized options underwriting & trading exchange, which supports Ethereum, Binance Smart Chain etc. Its similar peers are Hegic and Binance Option, semi-decentralized and centralized in nature respectively. 

At its initial launch, Option Panda will focus on providing traditional cryptocurrency (wBTC/ETH/BNB etc.) option trading on Binance Smart Chain, with gradual listing of more underlying assets. In 2021, we'll add CBBC(Callable Bull/Bear Contracts), which is a variant of options, to expand the product line. It's also a work in progress to support Ethereum Optimistic Rollup network, Algorand etc., for users of those public chains to trade options. Integration and combination with other decentralized asset trading platforms or protocols are also under rigorous consideration. Option Panda is gonna evolve to a composable exotic derivatives trading platform. 

Option Panda has many advantages against other option trading platforms.
* Scalable: Option Panda is a decentralized exchange which enables crypto asset traders to trade against each others’ price trend perspective regarding a certain underlying asset. Option Panda is scalable both in terms of crypto asset classes and expiry dates. Three underlying assets (wBTC, ETH, BNB) are listed for option offerings at the initial launch, with five available expiry durations, 5 minutes, 15 minutes, 30 minutes, 45 minutes, 1 hour, respectively. On Option Panda, actually it's quite simple to offer options for a new underlying asset, with any expiry duration. The power of deciding whether more assets or expiry durations should be provided is owned by Option Panda Community. We'll later announce our new asset listing and governance rules.
* Convenient: Option Panda automatically settles expiring options and updates new option offerings according to transparent rules. Option holders don't have to tower-watch and manually exercise their holdings through smart contract interaction. Option buyers simply buy a call/put option on the platform, waiting for its settlement for prospective profit; option sellers simply deposit underlying asset to a pool to participate in a pooled option underwriting, collecting premiums paid by option buyers.
* Transparent & Fair Pricing: Option Panda adopts a transparent option pricing mechanism. As there is no scientifically accurate pricing model for options, it's unfair to claim that any pricing mechanism is fair to everyone. One can only claim that the price is accepted and willingly taken by someone. However, Option Panda strives to do its best to create a technically fair option pricing mechanism. 
* Dynamic Sigma Adjustment: Option Panda employs a novel dynamic adjustment mechanism based on market supply/demand to achieve a relatively frequent update of the implied volatility in the option pricing formula, which we call it Dynamic Sigma Adjustment. It is designed this way so that the frequent, market oriented Sigma(volatility) adjustment could reflect the market supply/demand trend and achieve a practically fair option pricing for both the buy and sell parties. 
* Community Driven: Option Panda plans to gradually transfer the governance ownership to the community, and let platform tokens holders to decide it's roadmap. That means Option Panda will have a decentralized governance mechanism.

**1. Basic Features**

Option Panda allows option underwriting and trading in a decentralized setting.  

Option buyers simply buy a call/put option on the platform, waiting for its settlement for prospective profit; option sellers simply deposit underlying asset to a pool to participate in a pooled option underwriting, collecting premiums paid by option buyers.

**2. Options Pricing**

Option Panda only generates ATM options. And we use a nice and delicate Black-Scholes model, combined with a Dynamic Sigma Adjustment mechanism to achieve real-time computation of option price. For more information, please refer to the User Manual:

https://optionpanda.gitbook.io/option-panda-user-manual/untitled/13.-how-the-price-that-i-have-to-pay-to-buy-an-option-is-determined-by-option-panda

**3. Option Underwriting Mechanism**

Option Panda adopts an auction-like option offering mechanism. Every cycle, after the old option expires, new option with the same expiry duration will be generated with a fixed offering amount. This offering amount is calculated based on the availability of underwriting pool at that moment. Buyers are able to purchase the option until the upper limit is hit.

**4. Options Settlement**

Option Panda automatically settles expiring options and updates new option offerings according to transparent rules. Option holders don't have to tower-watch and manually exercise their holdings through smart contract interaction. 

All the above feature are running on Ethereum smart contract. Try it out!


## Contract Deployments On BSC

* CDF: 0x15fae9fAA97606cEB9701ea363E20CC72d32fE94
* Factory: 0xddE5b0c676d6A94540F5A2A91C7a5b75eaCBBEe0
* OPA Token: 0xA2F89a3be1bAda5Eb9D58D23EDc2E2FE0F82F4b0
* AggregateUpdater:0xbD55090FfA63BcE2C07516FDE1BBfe93361D1e91

| Pool | Address |
|------|------|
|BNB/USDT Call| 0x2D8a65606F7F9D08d532e1079ba57B1aF7acAB9e|
|BNB/USDT Put| 0xd7BdA2C32C3f82663a75e1AeAE1Cb9D6bE6d5119|
|BTCB/USDT Call|0xD9D31e22090A56aaD6491462Cb1E27E99c351Cf9|
|BTCB/USDT Put|0x1B5510B9bc81f596D9F61f9D0b19bBBB1DF7e868|
|ETH/USDT Call|0x698FE8e4421a9Ed2B0a0F0b0aD456Ea55202a055|
|ETH/USDT Put|0xaAdCCAf9FF0546A37e46C7e4A7c245Fd4a554a49|


