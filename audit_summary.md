# AUDIT SUMMARY

2022-02-09  

https://github.com/ghoul-sol/treasure-staking/commit/b16d6e11be193ed89663c2298b2189b1dff1ac25

Audited contracts:
- MasterOfCoin
- AtlasMine

----

Audit goal is to discover issues and vulnerabilities of the above contracts:
- check vectors attack
- check best practices
- check for gas savings
- ensure contract logic meets the specifications

It was done by line-by-line manual review.

----

Comments in code are made using this prefixes:
- `//-- ` this is comment to address by developer
- `//@@ ` this is my comment when trying to figure out logic 

----

## Risk and critical issues

There was no critical issues with the code.

## Major problems

### Upgradable contracts (proxy)

Using Upgradeable contracts is a major risk.  

There was many hacks in the past, using Upgradeable contracts. 
I strongly suggest not to use it, unless absolutely necessary.  
Everything here looks upgradeable, maybe it would be easier to write desktop app? ;)  
Seriously, this is the biggest risk of this code and if this functionality is really required you should be 
careful with any upgradeable action. @openzeppelin/contracts package has newest version, so at least all
known bugs are fixed. Before deployments please check if there is newer version and update.

### Tokens updates

Contracts allow to update tokens addresses (even if tokens itself can be upgradable). 
This can lead to unexpected math issues described in details in comments.  
Owner of the contract can cheat and distribute some fake tokens that way.

### Reentrancy

There is one place in code where we are not protected against reentrancy attack. I suggested simple fix.

## Minor issues

1. Execution of `recalculateLpAmount` can run out of gas is some cases.

## Code improvements

Most of the findings are gas savings.

- I made few comments about `unchecked` some lines (I will leave them as comments). Normally, I would suggest uncheck
all math related to tokens amounts/balances/rewards calculations, because there is no risk involved. If token will not
overflow, calculations in this contract will not as well, this would save a lot of gas.  
**BUT** - there are upgradable contracts everywhere, even more - there are methods to update tokens addresses, that
means there is edge case scenario where we can overflow because we can work with two different tokens, so we are not
protected with overflow inside token anymore.

  In this case, it is safer to leave all native checks for safemath.  
If you care about gas (you should) then there would be a way to save it: you need to make sure max total supplies of all
tokens (current + next onces/upragable) can be store under uint256. if that is the case we can uncheck math.

## Final recommendations

I strongly recommend addressing all above issues. 
