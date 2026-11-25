public with sharing class OrdersSignature {
    public static Boolean isValid(Blob body, String signature, String secret) {
        if (body == null || String.isBlank(secret) || String.isBlank(signature)
            || !Pattern.matches('^[a-fA-F0-9]{64}$', signature)) {
            return false;
        }
        return Crypto.verifyHMac('HmacSHA256', body, Blob.valueOf(secret),
            EncodingUtil.convertFromHex(signature));
    }
}
