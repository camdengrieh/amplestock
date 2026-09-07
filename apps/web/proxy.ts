// SPDX-License-Identifier: MIT

/**
 * The IP half of the geo gate. Next 16 calls this file `proxy.ts`; it is what earlier versions
 * called middleware, and it runs before every matched request.
 *
 * The provider is pluggable (`GEO_PROVIDER`) because the country header differs per host and
 * because plenty of deployments have none at all. When there is no signal the request is *not*
 * blocked — it is marked, and the app tells the user that the attestation is the only check
 * standing. Pretending to have checked would be worse than saying so.
 *
 * `/blocked` and `/risk` stay reachable from everywhere: somebody who has been blocked should
 * still be able to read why.
 */

import {NextResponse, type NextRequest} from 'next/server'

import {createGeoProvider, decideGeo, isAlwaysAllowed, parseBlockedCountries} from './lib/geo'

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)'],
}

export default function proxy(request: NextRequest) {
  const provider = createGeoProvider(process.env.GEO_PROVIDER, process.env.GEO_COUNTRY_HEADER ?? 'x-geo-country')
  const decision = decideGeo({
    headers: request.headers,
    provider,
    blocked: parseBlockedCountries(process.env.GEO_BLOCKED_COUNTRIES),
  })

  if (decision.blocked && !isAlwaysAllowed(request.nextUrl.pathname)) {
    const url = request.nextUrl.clone()
    url.pathname = '/blocked'
    url.search = ''
    const response = NextResponse.rewrite(url)
    response.headers.set('x-amps-geo', decision.country ?? 'unknown')
    response.headers.set('x-amps-geo-blocked', '1')
    return response
  }

  const response = NextResponse.next()
  response.headers.set('x-amps-geo', decision.country ?? 'unknown')
  response.headers.set('x-amps-geo-provider', decision.provider)
  response.headers.set('x-amps-geo-blocked', '0')
  if (decision.unverified) response.headers.set('x-amps-geo-unverified', '1')
  return response
}
