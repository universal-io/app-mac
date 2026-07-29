/**
 * The product site, named once. This host (api.universal-io.com) is the Gateway
 * and auth surface only; marketing and pricing live on the other host, so any
 * page here that needs to hand a visitor back reaches for this.
 *
 * The apex redirects to www, so link to www directly and skip the extra hop.
 */
export const PRODUCT_SITE_URL = "https://www.universal-io.com";
