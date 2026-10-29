#include <math.h>
#include <pulse/error.h>
#include <pulse/simple.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: noctalia-mic-meter SOURCE LEASE\n");
        return 2;
    }

    const pa_sample_spec spec = {
        .format = PA_SAMPLE_FLOAT32NE,
        .rate = 48000,
        .channels = 1,
    };
    const pa_buffer_attr attr = {
        .maxlength = (uint32_t)-1,
        .fragsize = 3200 * sizeof(float),
    };
    int error;
    pa_simple *stream = pa_simple_new(NULL, "Noctalia microphone meter",
                                      PA_STREAM_RECORD, argv[1], "Peak meter",
                                      &spec, NULL, &attr, &error);
    if (!stream) {
        fprintf(stderr, "microphone meter: %s\n", pa_strerror(error));
        return 1;
    }

    float samples[3200];
    while (access(argv[2], F_OK) == 0 &&
           pa_simple_read(stream, samples, sizeof(samples), &error) == 0) {
        float peak = 0;
        for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); i++) {
            float value = fabsf(samples[i]);
            if (value > peak) peak = value;
        }
        if (printf("%.6f\n", peak) < 0 || fflush(stdout) == EOF) break;
    }
    pa_simple_free(stream);
    return 0;
}
