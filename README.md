# AMQConnector

Connects proprietary software to FreePBX-based PBX by reading messages from
ActiveMQ, creating FreepPBX web requests, and altering the extensions tables.

## Files

**TiedMailbox.pm**    : A Mailbox object you can tie to a hash, used by amqconnector

**amqconnector.pl**        : The rewritten replacement for amqconnector.
**amqconnector-die.patch** : A patch for the original amqconnector that at least gets it to log why it died.
**amqconnector.conf**	  : /etc/amqconnector.conf

**install**           : bash script
**logrotate.conf**    : Rotates /var/log/amqconnector.log
**_test.pl**          : Test harness
**t/test_\***          : Tests

### amqconnector.pl

AMQConnector updates mailbox information by watching activemq for requests from the Hospitality component, altering the Asterisk DB via a tied hash, making FreePBX web requests, and repushing messages that need to be read by other consumers.

## Change Summary

- Added annoyingly pedantic but nicely descriptive logging functionality.
- Added error trapping and signal handling. Script doesn't die when temporarily unable to connect to activemq or when services aren't running.
- Added check and restart of activemq and freedom service. The queue receive loop sets SIGALRM to wake up for this.
- Moved configuration into one big Config hash, with the intent of moving it to /etc/amqconnector.conf so the script wouldn't have to be edited.
- Factored out mailbox updates into TiedMailbox.pm, which can be tied to a hash.

## Dependencies

The following packages are included in the standard Perl distribution ( the core ):
- Test::More
- Carp
- Data::Dumper

The following packages can be installed via CPAN or the system package manager:
- DBI
- Digest::MD5
- HTML::Form
- HTTP::Cookies
- LWP
- Net::Stomp
- Time::HiRes

