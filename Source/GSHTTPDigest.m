/* Implementation for GSHTTPAuthentication for GNUstep
   Copyright (C) 2006 Software Foundation, Inc.

   Written by:  Richard Frith-Macdonald <frm@gnu.org>
   Date: 2006
   
   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.
   
   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.
   */ 

#include "GSURLPrivate.h"
#include "Foundation/NSDictionary.h"
#include "Foundation/NSScanner.h"
#include "Foundation/NSSet.h"
#include "Foundation/NSDebug.h"
#include "GNUstepBase/GSLock.h"
#include "GNUstepBase/GSMime.h"


static NSMutableDictionary	*domainMap = nil;
static NSMutableSet		*spaces = nil;
static NSMutableDictionary	*store = nil;
static GSLazyLock		*storeLock = nil;
static GSMimeParser		*mimeParser = nil;

@interface NSData(GSHTTPDigest)
- (NSString*) digestHex;
@end
@implementation NSData(GSHTTPDigest)
- (NSString*) digestHex
{
  static const char	*hexChars = "0123456789abcdef";
  unsigned		slen = [self length];
  unsigned		dlen = slen * 2;
  const unsigned char	*src = (const unsigned char *)[self bytes];
  char			*dst = (char*)NSZoneMalloc(NSDefaultMallocZone(), dlen);
  unsigned		spos = 0;
  unsigned		dpos = 0;
  NSData		*data;
  NSString		*string;

  while (spos < slen)
    {
      unsigned char	c = src[spos++];

      dst[dpos++] = hexChars[(c >> 4) & 0x0f];
      dst[dpos++] = hexChars[c & 0x0f];
    }
  data = [NSData allocWithZone: NSDefaultMallocZone()];
  data = [data initWithBytesNoCopy: dst length: dlen];
  string = [[NSString alloc] initWithData: data
				 encoding: NSASCIIStringEncoding];
  RELEASE(data);
  return AUTORELEASE(string);
}
@end



@implementation GSHTTPAuthentication

+ (void) initialize
{
  if (store == nil)
    {
      mimeParser = [GSMimeParser new];
      spaces = [NSMutableSet new];
      domainMap = [NSMutableDictionary new];
      store = [NSMutableDictionary new];
      storeLock = [GSLazyLock new];
    }
}

+ (GSHTTPAuthentication *) digestWithCredential: (NSURLCredential*)credential
			      inProtectionSpace: (NSURLProtectionSpace*)space
{
  NSMutableDictionary	*cDict;
  NSURLProtectionSpace	*known;
  GSHTTPAuthentication	*digest = nil;

  [storeLock lock];
  /*
   * Keep track of known protection spaces so we don't make lots of
   * duplicate copies, but share one copy between digest objects.
   */
  known = [spaces member: space];
  if (known == nil)
    {
      [spaces addObject: space];
      known = [spaces member: space];
    }
  space = known;
  cDict = [store objectForKey: space];
  if (cDict == nil)
    {
      cDict = [NSMutableDictionary new];
      [store setObject: cDict forKey: space];
      RELEASE(cDict);
    }
  digest = [cDict objectForKey: credential];
  if (digest == nil)
    {
      digest = [[GSHTTPAuthentication alloc] initWithCredential: credential
					      inProtectionSpace: space];
      [cDict setObject: digest forKey: [digest credential]];
    }
  else
    {
      RETAIN(digest);
    }
  [storeLock unlock];
  return AUTORELEASE(digest);
}

+ (NSURLProtectionSpace*) protectionSpaceForAuthentication: (NSString*)auth
                                                requestURL: (NSURL*)URL;
{
  if (auth != nil)
    {
      NSString			*method = nil;
      NSURLProtectionSpace	*space;
      NSScanner			*sc;
      NSString			*domain = nil;
      NSString			*realm = nil;
      NSString			*key;
      NSString			*val;

      space = [self protectionSpaceForURL: URL];
      sc = [NSScanner scannerWithString: auth];
      if ([sc scanString: @"Basic" intoString: 0] == YES)
        {
	  method = NSURLAuthenticationMethodHTTPBasic;
	}
      else if ([sc scanString: @"Digest" intoString: 0] == NO)
        {
	  method = NSURLAuthenticationMethodHTTPDigest;
	}
      else
	{
	  return nil;	// Not a known authentication
	}
      while ((key = [mimeParser scanName: sc]) != nil)
	{
	  if ([sc scanString: @"=" intoString: 0] == NO)
	    {
	      return nil;	// Bad name=value specification
	    }
	  if ((val = [mimeParser scanToken: sc]) == nil)
	    {
	      return nil;	// Bad name=value specification
	    }
	  if ([key caseInsensitiveCompare: @"domain"] == NSOrderedSame)
	    {
	      domain = val;
	    }
	  else if ([key caseInsensitiveCompare: @"realm"] == NSOrderedSame)
	    {
	      realm = val;
	    }
	}
      if (realm == nil)
        {
	  return nil;		// No real to authenticate in
	}

      /*
       * If the realm and authentication method match the space we
       * found for the URL, assume that it is unchanged.
       */
      if ([[space realm] isEqualToString: realm]
	&& [[space authenticationMethod] isEqualToString: method])
	{
	  return space;
	}

      space = [[NSURLProtectionSpace alloc] initWithHost: [URL host]
						    port: [[URL port] intValue]
						protocol: [URL scheme]
						   realm: realm
				    authenticationMethod: method];
      [self setProtectionSpace: space
		    forDomains: [domain componentsSeparatedByString: @" "]
		       baseURL: URL];
      return AUTORELEASE(space);
    }
  return nil;
}

+ (NSURLProtectionSpace *) protectionSpaceForURL: (NSURL*)URL
{
  NSURLProtectionSpace	*space = nil;
  NSString		*found = nil;
  NSString		*scheme;
  NSNumber		*port;
  NSString		*server;
  NSDictionary		*sDict;
  NSArray		*keys;
  unsigned		count;
  NSString		*path;

  scheme = [URL scheme];
  port = [URL port];
  if ([port intValue] == 80 && [scheme isEqualToString: @"http"])
    {
      port = nil;
    }
  else if ([port intValue] == 443 && [scheme isEqualToString: @"https"])
    {
      port = nil;
    }
  if ([port intValue] == 0)
    {
      server = [NSString stringWithFormat: @"%@://%@",
	scheme, [URL host]];
    }
  else
    {
      server = [NSString stringWithFormat: @"%@://%@:%@",
	scheme, [URL host], port];
    }
  [storeLock lock];
  sDict = [domainMap objectForKey: server];
  keys = [sDict allKeys];
  count = [keys count];
  path = [URL path];
  while (count-- > 0)
    {
      NSString	*key = [keys objectAtIndex: count];

      if (found == nil || [key length] > [found length])
        {
	  if ([path hasPrefix: key] == YES)
	    {
	      found = key;
	    }
	}
    }
  if (found != nil)
    {
      space = RETAIN([sDict objectForKey: found]);
    }
  [storeLock unlock];
  return AUTORELEASE(space);
}

+ (void) setProtectionSpace: (NSURLProtectionSpace *)space
		 forDomains: (NSArray*)domains
		    baseURL: (NSURL*)base
{
  NSEnumerator	*e;
  NSString	*domain;

  /*
   * If there are no URIs specified, everything on the
   * host of the base URL is in the protection space
   */
  if ([domains count] == 0)
    {
      domains = [NSArray arrayWithObject: @"/"];
    }

  [storeLock lock];
  e = [domains objectEnumerator];
  while ((domain = [e nextObject]) != nil)
    {
      NSURL			*u;
      NSNumber			*port;
      NSString			*scheme;
      NSString			*server;
      NSMutableDictionary	*sDict;

      u = [NSURL URLWithString: domain];
      if (u == nil)
        {
          u = [NSURL URLWithString: domain relativeToURL: base];
	}
      port = [u port];
      scheme = [u scheme];
      if ([port intValue] == 80 && [scheme isEqualToString: @"http"])
        {
	  port = nil;
	}
      else if ([port intValue] == 443 && [scheme isEqualToString: @"https"])
        {
	  port = nil;
	}
      if ([port intValue] == 0)
        {
          server = [NSString stringWithFormat: @"%@://%@",
	    scheme, [u host]];
        }
      else
        {
          server = [NSString stringWithFormat: @"%@://%@:%@",
	    scheme, [u host], port];
	}
      sDict = [domainMap objectForKey: server];
      if (sDict == nil)
        {
	  sDict = [NSMutableDictionary new];
	  [domainMap setObject: sDict forKey: server];
	  RELEASE(sDict);
	}
      [sDict setObject: space forKey: [u path]];
    }
  [storeLock unlock];
}

- (NSString*) authorizationForAuthentication: (NSString*)authentication
				      method: (NSString*)method
					path: (NSString*)path
{
  NSString		*realm = nil;
  NSString		*qop = nil;
  NSString		*nonce = nil;
  NSString		*opaque = nil;
  NSString		*stale = @"FALSE";
  NSString		*algorithm = @"MD5";
  NSString		*cnonce;
  NSString		*HA1;
  NSString		*HA2;
  NSString		*response;
  NSMutableString	*authorisation;
  int			nc;

  if (authentication != nil)
    {
      NSScanner		*sc;
      NSString		*key;
      NSString		*val;

      sc = [NSScanner scannerWithString: authentication];
      if ([sc scanString: @"Digest" intoString: 0] == NO)
	{
	  NSDebugMLog(@"Bad format HTTP digest in '%@'", authentication);
	  return nil;	// Not a digest authentication
	}
      while ((key = [mimeParser scanName: sc]) != nil)
	{
	  if ([sc scanString: @"=" intoString: 0] == NO)
	    {
	      NSDebugMLog(@"Missing '=' in HTTP digest '%@'", authentication);
	      return nil;	// Bad name=value specification
	    }
	  if ((val = [mimeParser scanToken: sc]) == nil)
	    {
	      NSDebugMLog(@"Missing value in HTTP digest '%@'", authentication);
	      return nil;	// Bad name=value specification
	    }
	  if ([key caseInsensitiveCompare: @"realm"] == NSOrderedSame)
	    {
	      realm = val;
	    }
	  if ([key caseInsensitiveCompare: @"qop"] == NSOrderedSame)
	    {
	      qop = val;
	    }
	  if ([key caseInsensitiveCompare: @"nonce"] == NSOrderedSame)
	    {
	      nonce = val;
	    }
	  if ([key caseInsensitiveCompare: @"opaque"] == NSOrderedSame)
	    {
	      opaque = val;
	    }
	  if ([key caseInsensitiveCompare: @"stale"] == NSOrderedSame)
	    {
	      stale = val;
	    }
	  if ([key caseInsensitiveCompare: @"algorithm"] == NSOrderedSame)
	    {
	      algorithm = val;
	    }
	  if ([sc scanString: @"," intoString: 0] == NO)
	    {
	      break;	// No more in list.
	    }
	}

      if (realm == nil)
	{
	  NSDebugMLog(@"Missing HTTP digest realm in '%@'", authentication);
	  return nil;
	}
      if ([realm isEqualToString: [self->_space realm]] == NO)
        {
	  NSDebugMLog(@"Bad HTTP digest realm in '%@'", authentication);
	  return nil;
	}
      if (nonce == nil)
	{
	  NSDebugMLog(@"Missing HTTP digest nonce in '%@'", authentication);
	  return nil;
	}

      if ([algorithm isEqualToString: @"MD5"] == NO)
        {
	  NSDebugMLog(@"Unsupported HTTP digest algorithm in '%@'",
	    authentication);
	  return nil;
	}
      if (![[qop componentsSeparatedByString: @","] containsObject: @"auth"])
        {
	  NSDebugMLog(@"Unsupported/missing HTTP digest qop in '%@'",
	    authentication);
	  return nil;
	}

      [self->_lock lock];
      if ([stale boolValue] == YES
	|| [nonce isEqualToString: _nonce] == NO)
	{
	  _nc = 1;
	}
      ASSIGN(_nonce, nonce);
      ASSIGN(_qop, qop);
      ASSIGN(_opaque, opaque);
    }
  else
    {
      [self->_lock lock];
      nonce = _nonce;
      opaque = _opaque;
      qop = _qop;
      realm = [self->_space realm];
    }

  nc = _nc++;

  qop = @"auth";

  cnonce = [[[[[NSProcessInfo processInfo] globallyUniqueString]
    dataUsingEncoding: NSUTF8StringEncoding] md5Digest] digestHex];

  HA1 = [[[[NSString stringWithFormat: @"%@:%@:%@",
    [self->_credential user], realm, [self->_credential password]]
    dataUsingEncoding: NSUTF8StringEncoding] md5Digest] digestHex];

  HA2 = [[[[NSString stringWithFormat: @"%@:%@", method, path]
    dataUsingEncoding: NSUTF8StringEncoding] md5Digest] digestHex];

  response = [[[[NSString stringWithFormat: @"%@:%@:%08x:%@:%@:%@",
    HA1, nonce, nc, cnonce, qop, HA2]
    dataUsingEncoding: NSUTF8StringEncoding] md5Digest] digestHex];

  authorisation = [NSMutableString stringWithCapacity: 512];
  [authorisation appendFormat:  @"Digest realm=\"%@\"", realm];
  [authorisation appendFormat:  @",username=\"%@\"", [self->_credential user]];
  [authorisation appendFormat:  @",nonce=\"%@\"", nonce];
  [authorisation appendFormat:  @",uri=\"%@\"", path];
  [authorisation appendFormat:  @",response=\"%@\"", response];
  [authorisation appendFormat:  @",qop=\"%@\"", qop];
  [authorisation appendFormat:  @",nc=%08x", nc];
  [authorisation appendFormat:  @",cnonce=\"%@\"", cnonce];
  if (opaque != nil)
    {
      [authorisation appendFormat:  @",opaque=\"%@\"", opaque];
    }

  [self->_lock unlock];
 
  return authorisation;
}

- (NSURLCredential *) credential
{
  return self->_credential;
}

- (void) dealloc
{
  RELEASE(_credential);
  RELEASE(_space);
  RELEASE(_nonce);
  RELEASE(_opaque);
  RELEASE(_qop);
  RELEASE(_lock);
  [super dealloc];
}

- (id) initWithCredential: (NSURLCredential*)credential
	inProtectionSpace: (NSURLProtectionSpace*)space
{
  if ((self = [super init]) != nil)
    {
      self->_lock = [GSLazyLock new];
      ASSIGN(self->_space, space);
      ASSIGN(self->_credential, credential);
    }
  return self;
}

- (NSURLProtectionSpace *) space
{
  return self->_space;
}
@end

