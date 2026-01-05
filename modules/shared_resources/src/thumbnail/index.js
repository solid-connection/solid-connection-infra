import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import sharp from 'sharp';

const s3Client = new S3Client({ region: 'ap-northeast-2' });

export const handler = async (event) => {
    console.log('Event received:', JSON.stringify(event, null, 2));

    try {
        // S3 이벤트에서 버킷과 객체 정보 추출
        const record = event.Records[0];
        const bucket = record.s3.bucket.name;
        const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));

        console.log(`Processing file: ${key} from bucket: ${bucket}`);

        // chat/images/ 폴더의 이미지 파일만 처리
        if (!key.startsWith('chat/images/')) {
            console.log('Not a chat image, skipping');
            return { statusCode: 200, body: 'Not a chat image' };
        }

        // 이미지 파일 확장자 확인
        const imageExtensions = ['.jpg', '.jpeg', '.png', '.webp'];
        if (!imageExtensions.some(ext => key.toLowerCase().endsWith(ext))) {
            console.log('Not an image file, skipping');
            return { statusCode: 200, body: 'Not an image file' };
        }

        // 이미 썸네일 파일인 경우 처리하지 않음 (무한 루프 방지)
        if (key.includes('_thumb')) {
            console.log('Already a thumbnail, skipping');
            return { statusCode: 200, body: 'Already a thumbnail' };
        }

        // 원본 이미지 다운로드 (AWS SDK v3 방식)
        console.log('Downloading original image...');
        const getCommand = new GetObjectCommand({ Bucket: bucket, Key: key });
        const response = await s3Client.send(getCommand);

        // Body를 Buffer로 변환
        const imageBuffer = await streamToBuffer(response.Body);

        // Sharp를 사용해 썸네일 생성
        console.log('Creating thumbnail...');
        const thumbnailBuffer = await sharp(imageBuffer)
            .resize(200, 200, {
                fit: 'inside',        // 비율 유지하면서 200x200 안에 맞춤
                withoutEnlargement: true  // 원본보다 크게 만들지 않음
            })
            .jpeg({ quality: 85 })    // JPEG 품질 85%
            .toBuffer();

        // 썸네일 파일명 생성
        const fileName = key.split('/').pop(); // 파일명만 추출
        const nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.'));
        const extension = fileName.substring(fileName.lastIndexOf('.'));
        const thumbnailKey = `chat/thumbnails/${nameWithoutExt}_thumb${extension}`;

        console.log(`Uploading thumbnail to: ${thumbnailKey}`);

        // 썸네일을 S3에 업로드 (AWS SDK v3 방식)
        const putCommand = new PutObjectCommand({
            Bucket: bucket,
            Key: thumbnailKey,
            Body: thumbnailBuffer,
            ContentType: 'image/jpeg',
            Metadata: {
                'original-key': key,
                'generated-by': 'thumbnail-lambda'
            }
        });

        await s3Client.send(putCommand);

        console.log(`Thumbnail created successfully: ${thumbnailKey}`);

        return {
            statusCode: 200,
            body: JSON.stringify({
                message: 'Thumbnail created successfully',
                original: key,
                thumbnail: thumbnailKey,
                thumbnailSize: thumbnailBuffer.length
            })
        };

    } catch (error) {
        console.error('Error creating thumbnail:', error);

        return {
            statusCode: 500,
            body: JSON.stringify({
                message: 'Error creating thumbnail',
                error: error.message
            })
        };
    }
};

// Stream을 Buffer로 변환하는 헬퍼 함수
async function streamToBuffer(stream) {
    const chunks = [];
    for await (const chunk of stream) {
        chunks.push(chunk);
    }
    return Buffer.concat(chunks);
}
