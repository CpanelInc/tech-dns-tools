Check suffix nameservers
========================

Files
-----
nscheck - Query suffix servers (tld servers) for a domain's nameservers and compare with results of NS query
index.cgi - web interface to nscheck script
.htaccess - Rewrites to enable pretty URL parameters

Command line example:
-----
./nscheck --ipv6 --verbose cpanel.net

URL example:
-----
http://nscheck.qlogicinc.com/cpanel.net/ipv6/verbose

TODO:
-----
* Move website to internal server
