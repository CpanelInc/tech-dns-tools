Check suffix nameservers
========================

Query suffix servers (tld servers) for a domain's nameservers and hint records


TODO:
-----

Deploy script for nscheck:

* Prerequisite: perl module to run remote ssh commands: sudo perl -MCPAN -e 'install Net::SSH::Expect'
  Docs: http://search.cpan.org/dist/Net-SSH-Expect/lib/Net/SSH/Expect.pod

* Commands basically need to be the following:
```shell
$ ssh qlogic@xenu.qlogicinc.com
$ cd ~/sites/dns-tools
$ newdir=`date +%s`
$ git clone git://gitweb.qlogicinc.com/dns-tools $newdir
$ if [ -d $newdir ]; then rm -f current && ln -s $newdir current; fi
```
