import http from 'k6/http';
import { sleep, check, fail } from 'k6';

// KST
const now = new Date();
const kstOffset = 9 * 60;          // 분 단위
const d   = new Date(now.getTime() + kstOffset * 60 * 1000);
const kst = d.toISOString().slice(0, 16);   // "yyyy-mm-ddTHH:MM"

// "mm/dd HH:MM"
const time = (() => {
  const [yyyy, mm, dd, hh, min] = kst.split(/[-T:]/);
  return `${mm}/${dd}  ${hh}:${min}`;
})();

const BASE_URL = __ENV.BASE_URL || 'https://api.stage.solid-connection.com';
const testId = 'whole-user-flow';

export const options = {
    scenarios: {
        user_flow: {
            executor: 'per-vu-iterations',  // VU별 반복
            vus: Number(__ENV.K6_VUS || 10),
            iterations: Number(__ENV.K6_ITERATIONS || 10),
            maxDuration: __ENV.K6_MAX_DURATION || '15m',
        },
      },
    tags: {
        testid: testId,
        time: time,
    },
};

function authHeadersWithTags(token) {
    return {
        headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json; charset=utf-8',
        },
        tags: {
            ...options.tags,
            time: time,
        },
    };
}

function login() {
    // __VU: 현재 VU 인덱스
    const email = `user${__VU}@example.com`;
    const password = 'password';

    const res = http.post(`${BASE_URL}/auth/email/sign-in`, JSON.stringify({
        email: email,
        password: password,
    }), {
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        tags: {
            name: '/auth/email/sign-in',
        }
    });
    if (res.status !== 200) {
        fail('로그인 실패');
    }
    return res.json('accessToken');
}

// universites
function getRecommendedUniversities(auth) {
    http.get(`${BASE_URL}/universities/recommend`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/universities/recommend',
        },
});
}
function likeUniversity(id, auth) {
    http.post(`${BASE_URL}/universities/${id}/like`, null, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/universities/{id}/like',
        },
    });
}
function isLikedUniversity(id, auth) {
    http.get(`${BASE_URL}/universities/${id}/like`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/universities/{id}/like',
        },
    });
}
function getLikedUniversities(auth) {
    http.get(`${BASE_URL}/universities/like`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/universities/like',
        },
});
}
function cancelLikeUniversity(id, auth) {
    http.del(`${BASE_URL}/universities/${id}/like`, null, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/universities/{id}/like',
        },
    });
}
function searchUniversities(params) {
    return http.get(`${BASE_URL}/universities/search?${params}`, {
        tags: {
            name: '/universities/search?{params}',
        },
});
}
function getDetailedUniversityInfo(id) {
    http.get(`${BASE_URL}/universities/${id}`, {
        tags: {
            name: '/universities/{id}',
        },
    });
}

// my
function getMyInfo(auth) {
    http.get(`${BASE_URL}/my`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/my',
        },
});
}

// users
function checkNicknameExists(nickname) {
    http.get(`${BASE_URL}/users/exists?nickname=${nickname}`, {
        tags: {
            name: '/users/exists?nickname={nickname}',
        },
    });
}

// boards
function getBoards(auth) {
    http.get(`${BASE_URL}/boards`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/boards',
        },
});
}
function getPostsByBoard(boardCode, auth) {
    http.get(`${BASE_URL}/boards/${boardCode}`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/boards/{boardCode}',
        },
    });
}

// posts
const createPostJson = open('./createPost.json', 'b');
function createPost(token) {
    const formData = {
        postCreateRequest: http.file(createPostJson, 'post.json', 'application/json'),
    };
    const res = http.post(`${BASE_URL}/posts`, formData, {
        headers: {
            Authorization: `Bearer ${token}`
        },
        tags: {
            testid: testId,
            time: time,
            name: '/posts'
        },
    });
    return res.json('id');
}
const updatePostJson = open('./updatePost.json', 'b');
function updatePost(postId, token) {
    const formData = {
        postUpdateRequest: http.file(updatePostJson, 'post.json', 'application/json'),
    };
    http.patch(`${BASE_URL}/posts/${postId}`, formData, {
        headers: {
            Authorization: `Bearer ${token}`
        },
        tags: {
            testid: testId,
            time: time,
            name: '/posts/{postId}'
        },
    });
}
function getPostDetail(postId, auth) {
    http.get(`${BASE_URL}/posts/${postId}`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/posts/{postId}',
        },
    });
}
function likePost(postId, auth) {
    http.post(`${BASE_URL}/posts/${postId}/like`, null, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/posts/{postId}/like',
        },
    });
}
function cancelLikePost(postId, auth) {
    http.del(`${BASE_URL}/posts/${postId}/like`, null, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/posts/{postId}/like',
        },
    });
}
function deletePost(postId, auth) {
    http.del(`${BASE_URL}/posts/${postId}`, null, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/posts/{postId}',
        },
    });
}

// comments
function createComment(postId, auth) {
    const res = http.post(
        `${BASE_URL}/comments`,
        JSON.stringify({ postId, content: '댓글', parentId: null }),
        {
            ...auth,
            tags: {
                ...auth.tags,
                name: '/comments',
            },
    });
    return res.json('id');
}
function updateComment(commentId, auth) {
    http.patch(
        `${BASE_URL}/comments/${commentId}`,
        JSON.stringify({ content: '댓글 수정' }),
        {
            ...auth,
            tags: {
                ...auth.tags,
                name: '/comments/{commentId}',
            },
        }
    );
}
function deleteComment(commentId, auth) {
    http.del(`${BASE_URL}/comments/${commentId}`, null, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/comments/{commentId}',
        },
    });
}

// scores
function getLanguageTests(auth) {
    return http.get(`${BASE_URL}/scores/language-tests`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/scores/language-tests',
        },
    });
}
function getGPAs(auth) {
    return http.get(`${BASE_URL}/scores/gpas`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/scores/gpas',
        },
    });
}

function requireArray(value, name) {
    if (!Array.isArray(value) || value.length === 0) {
        fail(`${name} response is empty or invalid`);
    }
    return value;
}

function requireId(value, name) {
    if (!value || value.id === undefined || value.id === null) {
        fail(`${name} response does not contain id`);
    }
    return value.id;
}

// applications
function apply(gpaScoreId, languageTestScoreId, universityId, auth) {
    http.post(`${BASE_URL}/applications`, JSON.stringify({
        gpaScoreId: gpaScoreId,
        languageTestScoreId: languageTestScoreId,
        universityChoiceRequest: {
            firstChoiceUniversityId: universityId,
            secondChoiceUniversityId: null,
            thirdChoiceUniversityId: null
        },
    }), {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/applications',
        },
    });
}

function getCompetitors(auth) {
    http.get(`${BASE_URL}/applications/competitors`, {
        ...auth,
        tags: {
            ...auth.tags,
            name: '/applications/competitors',
        },
    });
}

export default function () {
    checkNicknameExists(encodeURIComponent('loadtest-user'));
    const token = login();
    const auth = authHeadersWithTags(token);


    getRecommendedUniversities(auth);

    const uniSearchRes = searchUniversities(''); // 이번학기 열린 대학 중 랜덤하게 id 가져오기
    const uniList = requireArray(uniSearchRes.json(), 'universities/search');
    const universityId = requireId(uniList[Math.floor(Math.random() * uniList.length)], 'universities/search item');

    likeUniversity(universityId, auth);
    isLikedUniversity(universityId, auth);
    getLikedUniversities(auth);
    cancelLikeUniversity(universityId, auth);
    getDetailedUniversityInfo(universityId);

    getMyInfo(auth);

    getBoards(auth);
    getPostsByBoard('FREE', auth);

    const postId = createPost(token);
    updatePost(postId, token);
    getPostDetail(postId, auth);
    likePost(postId, auth);
    cancelLikePost(postId, auth);

    const commentId = createComment(postId, auth);
    updateComment(commentId, auth);
    deleteComment(commentId, auth);

    deletePost(postId, auth);

    const langRes = getLanguageTests(auth);
    const langList = requireArray(langRes.json().languageTestScoreStatusResponseList, 'scores/language-tests');
    const languageTestScoreId = requireId(langList[0], 'scores/language-tests item');

    const gpaRes = getGPAs(auth);
    const gpaList = requireArray(gpaRes.json().gpaScoreStatusResponseList, 'scores/gpas');
    const gpaScoreId = requireId(gpaList[0], 'scores/gpas item');

    apply(gpaScoreId, languageTestScoreId, universityId, auth);
    getCompetitors(auth);

    sleep(1);
}
