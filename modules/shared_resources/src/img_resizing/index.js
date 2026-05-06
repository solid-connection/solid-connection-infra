const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const sharp = require("sharp");
const util = require("util");

const s3 = new S3Client({ region: "ap-northeast-2" });
const SOURCE_PREFIX = "original/";
const DESTINATION_PREFIX = "resize/";
const SUPPORTED_IMAGE_TYPES = new Set(["jpg", "jpeg", "png"]);

exports.handler = async (event) => {
    console.log("Reading options from event:\n", util.inspect(event, { depth: 5 }));

    const records = event?.Records ?? [];
    if (records.length === 0) {
        console.log("No S3 records found. Skipping.");
        return;
    }

    for (const record of records) {
        await resizeImage(record);
    }
};

async function resizeImage(record) {
    const srcBucket = record?.s3?.bucket?.name;
    const objectKey = record?.s3?.object?.key;

    if (!srcBucket || !objectKey) {
        console.log("Invalid S3 record. Skipping.");
        return;
    }

    const srcKey = decodeURIComponent(objectKey.replace(/\+/g, " "));
    if (!srcKey.startsWith(SOURCE_PREFIX)) {
        console.log(`Not an original image. Skipping: ${srcKey}`);
        return;
    }

    const typeMatch = srcKey.match(/\.([^.]*)$/);
    if (!typeMatch) {
        console.log(`Could not determine the image type: ${srcKey}`);
        return;
    }

    const imageType = typeMatch[1].toLowerCase();
    if (!SUPPORTED_IMAGE_TYPES.has(imageType)) {
        console.log(`Unsupported image type: ${imageType}`);
        return;
    }

    const dstKey = srcKey.replace(SOURCE_PREFIX, DESTINATION_PREFIX).replace(/\.[^.]+$/, ".webp");

    const response = await s3.send(new GetObjectCommand({
        Bucket: srcBucket,
        Key: srcKey,
    }));

    const contentBuffer = await streamToBuffer(response.Body);
    const outputBuffer = await sharp(contentBuffer)
        .resize(600)
        .webp()
        .toBuffer();

    await s3.send(new PutObjectCommand({
        Bucket: srcBucket,
        Key: dstKey,
        Body: outputBuffer,
        ContentType: "image/webp",
    }));

    console.log(`Successfully resized ${srcBucket}/${srcKey} and uploaded to ${srcBucket}/${dstKey}`);
}

async function streamToBuffer(stream) {
    const chunks = [];
    for await (const chunk of stream) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
}
