/**
 * @description Resolves Product2 Ids to deliverable product image URLs.
 *
 * Images live in ProductMedia (ProductId -> ElectronicMediaId -> CMS
 * ManagedContentVersion). CMS objects are not SOQL-queryable, so resolution
 * goes through the Commerce Connect API, which returns a ready-to-use image
 * URL. The guest browser must be able to load that URL without Salesforce
 * auth (e.g. externally hosted CMS images). This class isolates that lookup so a
 * missing/failed image never breaks the return builder — callers that get no
 * URL back simply render a fallback tile.
 *
 * ConnectApi.CommerceCatalog.getProduct is an internal API call: 0 SOQL/DML,
 * no Remote Site Setting, no callout-limit cost. The only query cost here is a
 * single WebStore lookup, done once regardless of how many products resolve.
 */
// `without sharing` + system-mode read. NOTE: ConnectApi.CommerceCatalog still
// enforces the RUNNING user's CRUD on the Commerce objects (WebStore, Product2,
// ProductCatalog, ...), so the agent user needs Read on them — see the
// Return_Builder_Agent permission set. Best-effort and exception-guarded, so a
// missing image never breaks the card.
public without sharing class ReturnBuilderImageResolver {

    // The API 67 overload takes webstoreId + productId + 12 null-safe params.
    private static final Integer EXTRA_PARAMS = 12;

    /**
     * @param product2Ids Product2 Ids to resolve.
     * @return Map of Product2 Id -> image URL. Products with no resolvable
     *         image are absent from the map (caller renders a fallback tile).
     */
    public static Map<Id, String> resolveImageUrls(Set<Id> product2Ids) {
        Map<Id, String> result = new Map<Id, String>();
        if (product2Ids == null || product2Ids.isEmpty()) {
            return result;
        }

        Id webstoreId = getWebStoreId();
        if (webstoreId == null) {
            return result;
        }

        for (Id productId : product2Ids) {
            String url = resolveOne(webstoreId, productId);
            if (String.isNotBlank(url)) {
                result.put(productId, url);
            }
        }
        return result;
    }

    private static Id getWebStoreId() {
        List<WebStore> stores = [SELECT Id FROM WebStore LIMIT 1];
        return stores.isEmpty() ? null : stores[0].Id;
    }

    private static String resolveOne(Id webstoreId, Id product2Id) {
        try {
            ConnectApi.ProductDetail pd = ConnectApi.CommerceCatalog.getProduct(
                webstoreId, String.valueOf(product2Id),
                null, null, null, null, null, null, null, null, null, null, null, null
            );

            if (pd.defaultImage != null && String.isNotBlank(pd.defaultImage.url)) {
                return pd.defaultImage.url;
            }

            // Fallback: first Image-type item in any media group.
            if (pd.mediaGroups != null) {
                for (ConnectApi.ProductMediaGroup grp : pd.mediaGroups) {
                    if (grp.mediaItems == null) {
                        continue;
                    }
                    for (ConnectApi.ProductMedia media : grp.mediaItems) {
                        if (String.valueOf(media.mediaType) == 'Image' && String.isNotBlank(media.url)) {
                            return media.url;
                        }
                    }
                }
            }
        } catch (Exception e) {
            // Swallow: an image failure must never break the return builder.
            System.debug(LoggingLevel.WARN, 'Image resolution failed for ' + product2Id + ': ' + e.getMessage());
        }
        return null;
    }
}
